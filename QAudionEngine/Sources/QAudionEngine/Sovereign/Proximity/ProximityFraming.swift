import Foundation

// Proximity pairing v1 — BLE framing (spec §7).
//
// Each ATT value (a write or a notification) is one fragment:
//
//   fragment = u8(flags) ‖ u8(seq) ‖ payload        (payload ≥ 1 byte)
//   flags    : 0x01 FIRST, 0x02 LAST, all other bits MUST be 0
//   seq      : 0 on FIRST, +1 per following fragment; at most 256 fragments
//
// A reassembled protocol message is at most `ProximityPairing.maxMessageBytes`
// (4096 B). Every framing error is a protocol violation that aborts the
// pairing; the reassembler never tries to resynchronise.

public enum ProximityFraming {

    /// `u8(flags) ‖ u8(seq)`.
    public static let headerBytes: Int = 2
    public static let flagFirst: UInt8 = 0x01
    public static let flagLast: UInt8 = 0x02

    /// seq is a u8, so one message spans at most 256 fragments (seq 0...255).
    fileprivate static let maxFragmentsPerMessage: Int = 256
    fileprivate static let knownFlags: UInt8 = 0x03

    /// Splits `message` (`type ‖ body`) into ATT values of at most
    /// `maxValueLength` bytes each (`ATT_MTU − 3`). Fragments are filled
    /// greedily, so every fragment but the last is exactly `maxValueLength`.
    ///
    /// Throws `.protocolViolation` for an empty message, a message larger than
    /// `ProximityPairing.maxMessageBytes`, `maxValueLength < 3`, or a split
    /// that would need more than 256 fragments.
    public static func fragments(of message: Data, maxValueLength: Int) throws -> [Data] {
        let body: Data = Data(message)
        guard !body.isEmpty else {
            throw ProximityPairingError.protocolViolation("empty message")
        }
        guard body.count <= ProximityPairing.maxMessageBytes else {
            throw ProximityPairingError.protocolViolation("message too large")
        }
        guard maxValueLength >= headerBytes + 1 else {
            throw ProximityPairingError.protocolViolation("ATT value too small")
        }

        let capacity: Int = maxValueLength - headerBytes
        // Overflow-free ceil(count / capacity): maxValueLength may be Int.max.
        let wholeChunks: Int = body.count / capacity
        let partialChunk: Int = (body.count % capacity == 0) ? 0 : 1
        let fragmentCount: Int = wholeChunks + partialChunk
        guard fragmentCount <= maxFragmentsPerMessage else {
            throw ProximityPairingError.protocolViolation("too many fragments")
        }

        var result: [Data] = []
        result.reserveCapacity(fragmentCount)
        var offset: Int = 0
        var seq: Int = 0
        while offset < body.count {
            let remaining: Int = body.count - offset
            let take: Int = min(remaining, capacity)
            let end: Int = offset + take

            var flags: UInt8 = 0
            if seq == 0 { flags |= flagFirst }
            if end == body.count { flags |= flagLast }
            let header: [UInt8] = [flags, UInt8(truncatingIfNeeded: seq)]

            var fragment = Data(capacity: headerBytes + take)
            fragment.append(contentsOf: header)
            fragment.append(body.subdata(in: offset..<end))
            result.append(fragment)

            offset = end
            seq += 1
        }
        return result
    }
}

/// Reassembles fragments produced by `ProximityFraming.fragments(of:maxValueLength:)`,
/// enforcing spec §7 exactly: unknown flag bits, an empty payload, a seq
/// mismatch, FIRST in the middle of a message, a message not starting with
/// FIRST, more than 256 fragments, or a reassembled size above
/// `maxMessageBytes` all throw `.protocolViolation`. After any throw the
/// reassembler has already reset itself (the pairing is aborted anyway).
public struct ProximityReassembler {

    private let maxMessageBytes: Int
    private var buffer: Data
    private var nextSeq: Int
    private var inMessage: Bool

    public init(maxMessageBytes: Int = ProximityPairing.maxMessageBytes) {
        self.maxMessageBytes = maxMessageBytes
        self.buffer = Data()
        self.nextSeq = 0
        self.inMessage = false
    }

    /// Feeds one ATT value. Returns the complete message when `fragment`
    /// carries LAST, otherwise nil.
    public mutating func append(_ fragment: Data) throws -> Data? {
        do {
            return try ingest(fragment)
        } catch {
            reset()
            throw error
        }
    }

    /// Drops any partial message.
    public mutating func reset() {
        buffer = Data()
        nextSeq = 0
        inMessage = false
    }

    private mutating func ingest(_ fragment: Data) throws -> Data? {
        let frame: Data = Data(fragment)
        let headerBytes: Int = ProximityFraming.headerBytes
        guard frame.count >= headerBytes else {
            throw ProximityPairingError.protocolViolation("fragment too short")
        }
        let flags: UInt8 = frame[0]
        let seq: Int = Int(frame[1])

        let unknownFlags: UInt8 = flags & ~ProximityFraming.knownFlags
        guard unknownFlags == 0 else {
            throw ProximityPairingError.protocolViolation("unknown fragment flags")
        }
        guard frame.count > headerBytes else {
            throw ProximityPairingError.protocolViolation("empty fragment payload")
        }

        let isFirst: Bool = (flags & ProximityFraming.flagFirst) != 0
        let isLast: Bool = (flags & ProximityFraming.flagLast) != 0

        if isFirst {
            guard !inMessage else {
                throw ProximityPairingError.protocolViolation("FIRST fragment inside a message")
            }
            guard seq == 0 else {
                throw ProximityPairingError.protocolViolation("fragment seq mismatch")
            }
            inMessage = true
            nextSeq = 0
            buffer = Data()
        } else {
            guard inMessage else {
                throw ProximityPairingError.protocolViolation("message does not start with FIRST")
            }
        }

        guard seq == nextSeq else {
            throw ProximityPairingError.protocolViolation("fragment seq mismatch")
        }

        let payloadCount: Int = frame.count - headerBytes
        // Written as a subtraction so it cannot overflow.
        guard payloadCount <= maxMessageBytes - buffer.count else {
            throw ProximityPairingError.protocolViolation("message too large")
        }
        buffer.append(frame.subdata(in: headerBytes..<frame.count))

        if isLast {
            let message: Data = buffer
            buffer = Data()
            nextSeq = 0
            inMessage = false
            return message
        }

        // seq 255 without LAST means the message needs a 257th fragment.
        guard seq + 1 < ProximityFraming.maxFragmentsPerMessage else {
            throw ProximityPairingError.protocolViolation("too many fragments")
        }
        nextSeq = seq + 1
        return nil
    }
}
