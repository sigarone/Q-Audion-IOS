import Foundation

/// The fixed tables of the filter bank, parsed from `fbank_tables.bin`: analysis window, FFT twiddles and mel filters.
struct VoiceFbankTables {
    static let frameLength = 400
    static let fftSize = 512
    static let numMel = 80
    static let twiddleCount = 256

    let window: [Float]
    let twiddleRe: [Float]
    /// Stored as the sine part with its sign already applied (the value to multiply with).
    let twiddleIm: [Float]
    let melFirst: [Int]
    let melCount: [Int]
    let melOffset: [Int]
    let melWeights: [Float]

    init(data: Data) throws {
        let headerBytes = 28
        guard data.count >= headerBytes, data.prefix(4) == Data("QVFT".utf8) else {
            throw VoiceBundleError.malformed("fbank tables: header")
        }
        func word(_ offset: Int) -> UInt32 {
            data.withUnsafeBytes { raw in
                UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
            }
        }
        let version = Int(word(4))
        let frame = Int(word(8))
        let fft = Int(word(12))
        let twiddles = Int(word(16))
        let mel = Int(word(20))
        let weightCount = Int(word(24))
        guard version == 1, frame == Self.frameLength, fft == Self.fftSize, twiddles == Self.twiddleCount,
              mel == Self.numMel, weightCount > 0 else {
            throw VoiceBundleError.malformed("fbank tables: geometry")
        }
        let words = frame + 2 * twiddles + 2 * mel + weightCount
        guard data.count == headerBytes + 4 * words else {
            throw VoiceBundleError.malformed("fbank tables: size")
        }
        var cursor = headerBytes
        func floats(_ count: Int) -> [Float] {
            var out = [Float]()
            out.reserveCapacity(count)
            for i in 0..<count {
                out.append(Float(bitPattern: word(cursor + 4 * i)))
            }
            cursor += 4 * count
            return out
        }
        func ints(_ count: Int) -> [Int] {
            var out = [Int]()
            out.reserveCapacity(count)
            for i in 0..<count {
                out.append(Int(word(cursor + 4 * i)))
            }
            cursor += 4 * count
            return out
        }
        let windowValues = floats(frame)
        let realValues = floats(twiddles)
        let imagValues = floats(twiddles)
        let firstValues = ints(mel)
        let countValues = ints(mel)
        let weightValues = floats(weightCount)
        var offsets = [0]
        offsets.reserveCapacity(mel + 1)
        var running = 0
        for count in countValues {
            running += count
            offsets.append(running)
        }
        guard running == weightCount else {
            throw VoiceBundleError.malformed("fbank tables: filter sizes")
        }
        for i in 0..<mel where firstValues[i] + countValues[i] > twiddles {
            throw VoiceBundleError.malformed("fbank tables: filter range")
        }
        window = windowValues
        twiddleRe = realValues
        twiddleIm = imagValues
        melFirst = firstValues
        melCount = countValues
        melOffset = offsets
        melWeights = weightValues
    }
}

/// The 80-bin log-mel front-end of one 65,536-sample window (408 frames), in float32 with a radix-2 FFT driven by the
/// shipped tables.
struct VoiceFbank {
    static let frameShift = 160
    static let windowSamples = 65_536
    static let frames = 1 + (windowSamples - VoiceFbankTables.frameLength) / frameShift

    private let tables: VoiceFbankTables
    private let preemphasis: Float
    private let logFloor: Float
    private let bitReversed: [Int]

    init(tables: VoiceFbankTables, constants: VoiceConstants.Fbank) {
        self.tables = tables
        self.preemphasis = Float(constants.preemph)
        self.logFloor = Float(constants.logFloor)
        let bits = 9
        var perm = [Int](repeating: 0, count: VoiceFbankTables.fftSize)
        for i in 0..<VoiceFbankTables.fftSize {
            var r = 0
            for b in 0..<bits where (i >> b) & 1 == 1 {
                r |= 1 << (bits - 1 - b)
            }
            perm[i] = r
        }
        self.bitReversed = perm
    }

    /// Log-mel energies before mean normalisation, row-major `frames x 80`.
    func logMel(_ samples: [Float]) -> [Float] {
        precondition(samples.count == Self.windowSamples, "a window is exactly 65,536 samples")
        let frameLength = VoiceFbankTables.frameLength
        let fftSize = VoiceFbankTables.fftSize
        let bins = VoiceFbankTables.twiddleCount
        let numMel = VoiceFbankTables.numMel
        var out = [Float](repeating: 0, count: Self.frames * numMel)
        var frame = [Float](repeating: 0, count: frameLength)
        var re = [Float](repeating: 0, count: fftSize)
        var im = [Float](repeating: 0, count: fftSize)
        var power = [Float](repeating: 0, count: bins)
        let divisor = Float(frameLength)

        for f in 0..<Self.frames {
            let start = f * Self.frameShift
            var sum: Float = 0
            for i in 0..<frameLength {
                sum += samples[start + i]
            }
            let mean = sum / divisor
            for i in 0..<frameLength {
                frame[i] = samples[start + i] - mean
            }
            // Pre-emphasis reads the mean-removed values, so it runs against a snapshot of the previous one.
            var previous = frame[0]
            for i in 0..<frameLength {
                let current = frame[i]
                frame[i] = current - preemphasis * previous
                previous = current
            }
            for i in 0..<frameLength {
                re[i] = frame[i] * tables.window[i]
            }
            for i in frameLength..<fftSize {
                re[i] = 0
            }
            for i in 0..<fftSize {
                im[i] = 0
            }
            transform(&re, &im)
            for k in 0..<bins {
                power[k] = re[k] * re[k] + im[k] * im[k]
            }
            for m in 0..<numMel {
                let first = tables.melFirst[m]
                let count = tables.melCount[m]
                let offset = tables.melOffset[m]
                var acc: Float = 0
                for j in 0..<count {
                    acc = acc + tables.melWeights[offset + j] * power[first + j]
                }
                let floored = acc > logFloor ? acc : logFloor
                out[f * numMel + m] = Float(log(Double(floored)))
            }
        }
        return out
    }

    /// Mean normalisation over the frames of one window (the mean of each bin accumulated in double precision).
    static func meanNormalised(_ logMel: [Float]) -> [Float] {
        let numMel = VoiceFbankTables.numMel
        let frameCount = logMel.count / numMel
        var out = logMel
        for m in 0..<numMel {
            var sum = 0.0
            for f in 0..<frameCount {
                sum += Double(logMel[f * numMel + m])
            }
            let mean = Float(sum / Double(frameCount))
            for f in 0..<frameCount {
                out[f * numMel + m] = logMel[f * numMel + m] - mean
            }
        }
        return out
    }

    /// 408 x 80 features after mean normalisation.
    func fbank(_ samples: [Float]) -> [Float] {
        Self.meanNormalised(logMel(samples))
    }

    /// Mean over frames of (mean of the high-band bins) minus (mean of the mid-band bins); inclusive bin ranges.
    static func bandwidth(_ logMel: [Float], high: [Int], low: [Int]) -> Double {
        let numMel = VoiceFbankTables.numMel
        let frameCount = logMel.count / numMel
        var total = 0.0
        for f in 0..<frameCount {
            total += bandMean(logMel, frame: f, range: high) - bandMean(logMel, frame: f, range: low)
        }
        return total / Double(frameCount)
    }

    private static func bandMean(_ logMel: [Float], frame: Int, range: [Int]) -> Double {
        var sum = 0.0
        for m in range[0]...range[1] {
            sum += Double(logMel[frame * VoiceFbankTables.numMel + m])
        }
        return sum / Double(range[1] - range[0] + 1)
    }

    /// In-place 512-point decimation-in-time FFT: bit reversal first, then butterflies stage by stage.
    private func transform(_ re: inout [Float], _ im: inout [Float]) {
        let n = VoiceFbankTables.fftSize
        for i in 0..<n {
            let j = bitReversed[i]
            if j > i {
                re.swapAt(i, j)
                im.swapAt(i, j)
            }
        }
        var length = 2
        while length <= n {
            let half = length / 2
            let stride = n / length
            var i = 0
            while i < n {
                for j in 0..<half {
                    let wr = tables.twiddleRe[j * stride]
                    let wi = tables.twiddleIm[j * stride]
                    let upper = i + j
                    let lower = upper + half
                    let ur = re[upper]
                    let ui = im[upper]
                    let xr = re[lower]
                    let xi = im[lower]
                    let vr = xr * wr - xi * wi
                    let vi = xr * wi + xi * wr
                    re[upper] = ur + vr
                    im[upper] = ui + vi
                    re[lower] = ur - vr
                    im[lower] = ui - vi
                }
                i += length
            }
            length *= 2
        }
    }
}
