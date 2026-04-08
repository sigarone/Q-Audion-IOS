import Foundation
#if canImport(Security)
import Security
#endif

public final class AdaptivePadding: @unchecked Sendable {
    public static let defaultTargetFrameSize = 256
    public let targetFrameSize: Int
    private let lock = NSLock()
    private var _totalFramesPadded: Int64 = 0
    private var _totalFramesUnpadded: Int64 = 0
    private var _totalPaddingBytes: Int64 = 0
    private var _totalRandomRatioSum: Int64 = 0  // fixed-point: ratio * 10000
    private static let ratioScale: Float = 10_000.0

    public init(targetFrameSize: Int = defaultTargetFrameSize) {
        precondition(targetFrameSize >= 2, "targetFrameSize must be >= 2")
        self.targetFrameSize = targetFrameSize
    }

    public func pad(encryptedPayload: Data, confidenceScore: Float) -> Data {
        precondition(confidenceScore >= 0.0 && confidenceScore <= 1.0)
        let payloadSize = encryptedPayload.count
        let outputSize: Int
        let paddingLength: Int
        if payloadSize >= targetFrameSize - 2 {
            outputSize = payloadSize + 2
            paddingLength = 0
        } else {
            outputSize = targetFrameSize
            paddingLength = targetFrameSize - payloadSize - 2
        }
        var output = Data(capacity: outputSize)
        output.append(encryptedPayload)
        if paddingLength > 0 {
            var randomBytes = Data(count: paddingLength)
            randomBytes.withUnsafeMutableBytes { buffer in
                #if canImport(Security)
                _ = SecRandomCopyBytes(kSecRandomDefault, paddingLength, buffer.baseAddress!)
                #else
                let fd = open("/dev/urandom", O_RDONLY)
                if fd >= 0 { _ = read(fd, buffer.baseAddress!, paddingLength); close(fd) }
                #endif
            }
            output.append(randomBytes)
        }
        output.append(UInt8((paddingLength >> 8) & 0xFF))
        output.append(UInt8(paddingLength & 0xFF))
        let randomRatio = 1.0 - confidenceScore
        lock.lock()
        _totalFramesPadded += 1
        _totalPaddingBytes += Int64(paddingLength)
        _totalRandomRatioSum += Int64(randomRatio * Self.ratioScale)
        lock.unlock()
        return output
    }

    public func unpad(paddedFrame: Data) throws -> Data {
        guard paddedFrame.count >= 2 else { throw AdaptivePaddingError.frameTooSmall }
        let highByte = Int(paddedFrame[paddedFrame.count - 2])
        let lowByte = Int(paddedFrame[paddedFrame.count - 1])
        let paddingLength = (highByte << 8) | lowByte
        let payloadSize = paddedFrame.count - paddingLength - 2
        guard payloadSize >= 0 else { throw AdaptivePaddingError.invalidPaddingLength(paddingLength) }
        lock.lock(); _totalFramesUnpadded += 1; lock.unlock()
        return paddedFrame.prefix(payloadSize)
    }

    public var statistics: PaddingStatistics {
        lock.lock(); defer { lock.unlock() }
        let avgRatio = _totalFramesPadded > 0 ? (Float(_totalRandomRatioSum) / Self.ratioScale) / Float(_totalFramesPadded) : 0
        return PaddingStatistics(totalFramesPadded: _totalFramesPadded,
            totalFramesUnpadded: _totalFramesUnpadded,
            averagePaddingBytes: _totalFramesPadded > 0 ? Float(_totalPaddingBytes) / Float(_totalFramesPadded) : 0,
            averageRandomRatio: avgRatio)
    }
}

public struct PaddingStatistics {
    public let totalFramesPadded: Int64
    public let totalFramesUnpadded: Int64
    public let averagePaddingBytes: Float
    public let averageRandomRatio: Float  // 0.0 = all zero-fill (high confidence), 1.0 = all random (low confidence)
}

public enum AdaptivePaddingError: Error {
    case frameTooSmall
    case invalidPaddingLength(Int)
}
