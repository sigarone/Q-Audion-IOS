import Foundation

public enum FrameEncoder {

    public static func serialize(_ frame: EncryptedFrame) -> Data {
        let hasDeepfakeScore = frame.deepfakeScore != nil
        let payloadLen = frame.payload.count
        let totalSize = TransportConstants.headerSize + payloadLen
            + TransportConstants.tagSize + (hasDeepfakeScore ? 4 : 0)

        var data = Data(capacity: totalSize)
        data.append(frame.version)
        var flags = frame.flags
        if hasDeepfakeScore { flags |= TransportConstants.flagHasDeepfakeScore }
        data.append(flags)
        appendUInt32BigEndian(&data, frame.sequenceNumber)
        appendUInt64BigEndian(&data, frame.timestamp)
        data.append(UInt8(TransportConstants.nonceSize))
        data.append(frame.nonce)
        appendUInt16BigEndian(&data, UInt16(payloadLen))
        data.append(frame.payload)
        data.append(frame.tag)
        if let score = frame.deepfakeScore {
            appendFloatBigEndian(&data, score)
        }
        return data
    }

    public static func deserialize(_ data: Data) throws -> EncryptedFrame {
        guard data.count >= TransportConstants.minFrameSize else {
            throw FrameEncoderError.frameTooSmall(data.count)
        }
        guard data.count <= TransportConstants.maxFrameSize else {
            throw FrameEncoderError.frameTooLarge(data.count)
        }
        var offset = 0
        let version = data[offset]; offset += 1
        guard version == TransportConstants.frameVersion else {
            throw FrameEncoderError.unsupportedVersion(version)
        }
        let flags = data[offset]; offset += 1
        guard (flags & ~TransportConstants.flagsValidMask) == 0 else {
            throw FrameEncoderError.invalidFlags(flags)
        }
        let seqNum = readUInt32BigEndian(data, offset: offset); offset += 4
        let timestamp = readUInt64BigEndian(data, offset: offset); offset += 8
        let nonceLen = Int(data[offset]); offset += 1
        guard nonceLen == TransportConstants.nonceSize else {
            throw FrameEncoderError.invalidNonceLength(nonceLen)
        }
        let nonce = data[offset..<(offset + nonceLen)]; offset += nonceLen
        let payloadLen = Int(readUInt16BigEndian(data, offset: offset)); offset += 2
        guard payloadLen <= TransportConstants.maxPayloadSize else {
            throw FrameEncoderError.payloadTooLarge(payloadLen)
        }
        guard offset + payloadLen + TransportConstants.tagSize <= data.count else {
            throw FrameEncoderError.frameTruncated
        }
        let payload = data[offset..<(offset + payloadLen)]; offset += payloadLen
        let tag = data[offset..<(offset + TransportConstants.tagSize)]; offset += TransportConstants.tagSize
        let hasDeepfakeScore = (flags & TransportConstants.flagHasDeepfakeScore) != 0
        var deepfakeScore: Float?
        if hasDeepfakeScore {
            guard data.count - offset >= 4 else { throw FrameEncoderError.frameTruncated }
            deepfakeScore = readFloatBigEndian(data, offset: offset); offset += 4
        }
        return EncryptedFrame(version: version, flags: flags, sequenceNumber: seqNum,
            timestamp: timestamp, nonce: Data(nonce), payload: Data(payload),
            tag: Data(tag), deepfakeScore: deepfakeScore)
    }

    public static func isValid(_ data: Data) -> Bool {
        guard data.count >= TransportConstants.minFrameSize,
              data.count <= TransportConstants.maxFrameSize,
              data[0] == TransportConstants.frameVersion,
              data[14] == UInt8(TransportConstants.nonceSize)
        else { return false }
        let payloadLen = Int(readUInt16BigEndian(data, offset: 27))
        return data.count >= TransportConstants.headerSize + payloadLen + TransportConstants.tagSize
    }

    public static func extractSequenceNumber(_ data: Data) -> UInt32 {
        precondition(data.count >= 6)
        return readUInt32BigEndian(data, offset: 2)
    }

    public static func extractTimestamp(_ data: Data) -> UInt64 {
        precondition(data.count >= 14)
        return readUInt64BigEndian(data, offset: 6)
    }

    // MARK: - Big-endian helpers
    private static func appendUInt16BigEndian(_ data: inout Data, _ value: UInt16) {
        var big = value.bigEndian
        data.append(Data(bytes: &big, count: 2))
    }
    private static func appendUInt32BigEndian(_ data: inout Data, _ value: UInt32) {
        var big = value.bigEndian
        data.append(Data(bytes: &big, count: 4))
    }
    private static func appendUInt64BigEndian(_ data: inout Data, _ value: UInt64) {
        var big = value.bigEndian
        data.append(Data(bytes: &big, count: 8))
    }
    private static func appendFloatBigEndian(_ data: inout Data, _ value: Float) {
        var bits = value.bitPattern.bigEndian
        data.append(Data(bytes: &bits, count: 4))
    }
    private static func readUInt16BigEndian(_ data: Data, offset: Int) -> UInt16 {
        data.withUnsafeBytes { UInt16(bigEndian: $0.load(fromByteOffset: offset, as: UInt16.self)) }
    }
    private static func readUInt32BigEndian(_ data: Data, offset: Int) -> UInt32 {
        data.withUnsafeBytes { UInt32(bigEndian: $0.load(fromByteOffset: offset, as: UInt32.self)) }
    }
    private static func readUInt64BigEndian(_ data: Data, offset: Int) -> UInt64 {
        data.withUnsafeBytes { UInt64(bigEndian: $0.load(fromByteOffset: offset, as: UInt64.self)) }
    }
    private static func readFloatBigEndian(_ data: Data, offset: Int) -> Float {
        let bits = data.withUnsafeBytes { UInt32(bigEndian: $0.load(fromByteOffset: offset, as: UInt32.self)) }
        return Float(bitPattern: bits)
    }
}

public enum FrameEncoderError: Error, Equatable {
    case frameTooSmall(Int)
    case frameTooLarge(Int)
    case unsupportedVersion(UInt8)
    case invalidFlags(UInt8)
    case invalidNonceLength(Int)
    case payloadTooLarge(Int)
    case frameTruncated
}
