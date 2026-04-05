import Foundation

/// Encrypted audio frame for Q-Audion wire transport.
public struct EncryptedFrame: Equatable {
    public let version: UInt8
    public let flags: UInt8
    public let sequenceNumber: UInt32
    public let timestamp: UInt64
    public let nonce: Data
    public let payload: Data
    public let tag: Data
    public let deepfakeScore: Float?

    public init(
        version: UInt8 = TransportConstants.frameVersion,
        flags: UInt8 = 0x00,
        sequenceNumber: UInt32,
        timestamp: UInt64,
        nonce: Data,
        payload: Data,
        tag: Data,
        deepfakeScore: Float? = nil
    ) {
        precondition(version == TransportConstants.frameVersion, "Unsupported frame version: \(version)")
        precondition((flags & ~TransportConstants.flagsValidMask) == 0, "Invalid flags: \(flags)")
        precondition(nonce.count == TransportConstants.nonceSize, "Nonce must be \(TransportConstants.nonceSize) bytes, got \(nonce.count)")
        precondition(payload.count <= TransportConstants.maxPayloadSize, "Payload exceeds max size: \(payload.count)")
        precondition(tag.count == TransportConstants.tagSize, "Tag must be \(TransportConstants.tagSize) bytes, got \(tag.count)")
        if let score = deepfakeScore {
            precondition(score >= TransportConstants.deepfakeScoreMin && score <= TransportConstants.deepfakeScoreMax, "Deepfake score out of range: \(score)")
        }
        self.version = version
        self.flags = flags
        self.sequenceNumber = sequenceNumber
        self.timestamp = timestamp
        self.nonce = nonce
        self.payload = payload
        self.tag = tag
        self.deepfakeScore = deepfakeScore
    }
}
