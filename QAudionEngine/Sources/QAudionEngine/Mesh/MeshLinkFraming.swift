import Foundation

/// Link framing of the Bluetooth mesh (docs/mesh/MESH_LINK_SPEC.md section 6).
///
/// A packet (`MeshPacket.encode()`) is split into frames that each fit one ATT
/// operation on the link they travel on:
///
///     offset  size  field
///     0       2     setId  (u16, big-endian)
///     2       1     index  (u8, 0-based)
///     3       1     total  (u8, 1..255)
///     4       n     chunk  (n >= 1)
///
/// Everything here is a pure data transform (no CoreBluetooth type, no clock of
/// its own), so it is pinned by the shared known-answer vectors on the plain
/// Swift package test target.
public enum MeshLinkFraming {

    public static let headerBytes = 4
    public static let maxFramesPerSet = 255
    /// The largest encoded packet: 16384 payload bytes behind the longest header
    /// (ttl, 255 source-route hops).
    public static let maxPacketBytes = 18_457

    public enum SplitError: Error, Equatable {
        /// `valueLimit - 4 < 1`: not even one chunk byte fits.
        case linkTooSmall
        /// More than 255 frames would be needed on this link.
        case tooManyFrames
    }

    /// Chunk bytes available per frame on a link whose value limit is `valueLimit`.
    public static func chunkBytes(valueLimit: Int) -> Int {
        valueLimit - headerBytes
    }

    /// Frames needed for `packetLength` bytes, or nil when the link is unusable
    /// or the count would exceed 255.
    public static func frameCount(packetLength: Int, valueLimit: Int) -> Int? {
        let chunk = chunkBytes(valueLimit: valueLimit)
        guard chunk >= 1 else { return nil }
        let total = max(1, (packetLength + chunk - 1) / chunk)
        return total <= maxFramesPerSet ? total : nil
    }

    /// A random `setId`: chosen for every transmission of every packet on every
    /// link, so a retransmission never reuses one.
    public static func randomSetId() -> UInt16 {
        UInt16.random(in: UInt16.min...UInt16.max)
    }

    /// Splits `packet` for a link whose value limit is `valueLimit`.
    public static func split(_ packet: Data, valueLimit: Int, setId: UInt16) -> Result<[Data], SplitError> {
        let chunk = chunkBytes(valueLimit: valueLimit)
        guard chunk >= 1 else { return .failure(.linkTooSmall) }
        let total = max(1, (packet.count + chunk - 1) / chunk)
        guard total <= maxFramesPerSet else { return .failure(.tooManyFrames) }
        var frames: [Data] = []
        frames.reserveCapacity(total)
        let base = packet.startIndex
        for index in 0..<total {
            let from = packet.index(base, offsetBy: index * chunk)
            let to = packet.index(from, offsetBy: min(chunk, packet.count - index * chunk))
            var frame = Data(capacity: headerBytes + (to - from))
            frame.append(UInt8(setId >> 8))
            frame.append(UInt8(setId & 0xFF))
            frame.append(UInt8(index))
            frame.append(UInt8(total))
            frame.append(packet[from..<to])
            frames.append(frame)
        }
        return .success(frames)
    }
}

// MARK: - Receiver

/// Reassembly of the frames received on ONE link (section 6.3).
///
/// Time is passed in (`nowMs`), never read, so expiry is testable. Sets are keyed
/// by `setId` inside the link; the owner keeps one reassembler per link.
public struct MeshLinkReassembler {

    /// An incomplete set is dropped this long after its most recent frame.
    public static let idleTimeoutMs: Int64 = 10_000
    /// ...and in any case this long after its first frame.
    public static let absoluteTimeoutMs: Int64 = 30_000
    /// Incomplete sets kept per link.
    public static let maxIncompleteSets = 4

    public enum MalformedReason: String, Equatable, Sendable {
        case shortFrame = "short_frame"
        case badHeader = "bad_header"
        case totalMismatch = "total_mismatch"
        case setTooLarge = "set_too_large"
    }

    public enum Status: Equatable {
        case pending
        case duplicateIgnored
        case complete(Data)
        case malformed(MalformedReason)

        /// The token the shared vectors use for the status.
        public var vectorToken: String {
            switch self {
            case .pending: return "pending"
            case .duplicateIgnored: return "duplicate_ignored"
            case .complete: return "complete"
            case .malformed(let reason): return "malformed:" + reason.rawValue
            }
        }
    }

    public struct Outcome: Equatable {
        public let status: Status
        /// Incomplete sets dropped by the idle/absolute timeouts before this frame was handled.
        public let expiredSets: Int
        /// Incomplete sets evicted to make room for this frame's set.
        public let evictedSets: Int
        /// Frames the completed set consisted of (0 unless `status` is `.complete`).
        public let completedFrames: Int
    }

    private struct OpenSet {
        let total: Int
        let firstFrameAtMs: Int64
        var lastFrameAtMs: Int64
        var chunks: [Int: Data] = [:]
        var bufferedBytes = 0
    }

    private var sets: [UInt16: OpenSet] = [:]

    public init() {}

    /// Incomplete sets currently held.
    public var pendingSetCount: Int { sets.count }

    public mutating func reset() {
        sets.removeAll()
    }

    /// Drops the sets past a timeout; returns how many were dropped.
    @discardableResult
    public mutating func sweep(nowMs: Int64) -> Int {
        let stale = sets.filter { _, set in
            nowMs - set.lastFrameAtMs > Self.idleTimeoutMs || nowMs - set.firstFrameAtMs > Self.absoluteTimeoutMs
        }
        for key in stale.keys { sets.removeValue(forKey: key) }
        return stale.count
    }

    public mutating func offer(_ frame: Data, nowMs: Int64) -> Outcome {
        let expired = sweep(nowMs: nowMs)
        func outcome(_ status: Status, evicted: Int = 0, frames: Int = 0) -> Outcome {
            Outcome(status: status, expiredSets: expired, evictedSets: evicted, completedFrames: frames)
        }
        guard frame.count >= MeshLinkFraming.headerBytes + 1 else { return outcome(.malformed(.shortFrame)) }
        let b = frame.startIndex
        let setId = (UInt16(frame[b]) << 8) | UInt16(frame[b + 1])
        let index = Int(frame[b + 2])
        let total = Int(frame[b + 3])
        let chunk = Data(frame[(b + MeshLinkFraming.headerBytes)...])
        guard total >= 1, index < total else { return outcome(.malformed(.badHeader)) }
        if total == 1 { return outcome(.complete(chunk), frames: 1) }

        var evicted = 0
        if let open = sets[setId] {
            if open.total != total {
                sets.removeValue(forKey: setId)
                return outcome(.malformed(.totalMismatch))
            }
        } else {
            while sets.count >= Self.maxIncompleteSets {
                // The set whose most recent frame is oldest makes room for the newcomer.
                guard let oldest = sets.min(by: { $0.value.lastFrameAtMs < $1.value.lastFrameAtMs })?.key else { break }
                sets.removeValue(forKey: oldest)
                evicted += 1
            }
            sets[setId] = OpenSet(total: total, firstFrameAtMs: nowMs, lastFrameAtMs: nowMs)
        }
        guard var open = sets[setId] else { return outcome(.pending, evicted: evicted) }
        if open.chunks[index] != nil { return outcome(.duplicateIgnored, evicted: evicted) }
        open.chunks[index] = chunk
        open.bufferedBytes += chunk.count
        open.lastFrameAtMs = nowMs
        if open.bufferedBytes > MeshLinkFraming.maxPacketBytes {
            sets.removeValue(forKey: setId)
            return outcome(.malformed(.setTooLarge), evicted: evicted)
        }
        if open.chunks.count == open.total {
            sets.removeValue(forKey: setId)
            var packet = Data()
            packet.reserveCapacity(open.bufferedBytes)
            for i in 0..<open.total {
                guard let part = open.chunks[i] else { return outcome(.malformed(.badHeader), evicted: evicted) }
                packet.append(part)
            }
            return outcome(.complete(packet), evicted: evicted, frames: open.total)
        }
        sets[setId] = open
        return outcome(.pending, evicted: evicted)
    }
}

// MARK: - Malformed streak

/// Per-link consecutive-malformed counter and the temporary block that follows
/// it (section 6.4). The key is whatever the platform uses to name a link (the
/// CoreBluetooth identifier). A block survives a restart of the antenna; the
/// owner therefore keeps one guard for the life of the transport and never
/// clears it in `stop()`.
public struct MeshMalformedGuard {

    public static let maxStreak = 10
    public static let blockMs: Int64 = 60_000

    private var streaks: [String: Int] = [:]
    private var blockedUntilMs: [String: Int64] = [:]

    public init() {}

    /// True while frames from `key` are ignored.
    public mutating func isBlocked(_ key: String, nowMs: Int64) -> Bool {
        guard let until = blockedUntilMs[key] else { return false }
        if nowMs >= until {
            blockedUntilMs.removeValue(forKey: key)
            return false
        }
        return true
    }

    /// Counts one malformed event. Returns the streak when this event tripped the
    /// block (the owner disconnects the link where it can), nil otherwise.
    public mutating func registerMalformed(_ key: String, nowMs: Int64) -> Int? {
        let streak = (streaks[key] ?? 0) + 1
        guard streak >= Self.maxStreak else {
            streaks[key] = streak
            return nil
        }
        streaks.removeValue(forKey: key)
        blockedUntilMs[key] = nowMs + Self.blockMs
        return streak
    }

    /// A well-formed packet resets the streak.
    public mutating func registerWellFormed(_ key: String) {
        streaks.removeValue(forKey: key)
    }

    public func streak(_ key: String) -> Int {
        streaks[key] ?? 0
    }

    /// A link is gone: its streak goes with it, a block does not.
    public mutating func linkGone(_ key: String) {
        streaks.removeValue(forKey: key)
    }
}

// MARK: - Sender

/// Why a frame (and with it the set it belongs to) was not accepted on a link
/// (the `reason` of the `tx.frame.fail` event).
public enum MeshFrameFailure: String, Equatable, Sendable {
    case tooBig = "too_big"
    case rejected
    case timeout
    case notReady = "not_ready"
    case linkLost = "link_lost"
    case tooManyFrames = "too_many_frames"
}

/// One set of frames on one link (section 6.2): at most one ATT operation is
/// outstanding, frames go out in index order, the next only after the previous
/// one is confirmed, and the first failure abandons the rest. A packet is
/// accepted on the link only if EVERY frame was.
public struct MeshFrameSetSender: Equatable {

    /// A frame not confirmed within this time fails the set.
    public static let frameTimeoutMs = 2_000

    public enum Step: Equatable {
        /// Put this frame on the air and wait for its confirmation.
        case send(Data)
        /// Every frame was accepted.
        case finished
        /// The set failed; nothing more is sent.
        case failed(MeshFrameFailure, frameIndex: Int)
    }

    public let frames: [Data]
    public private(set) var nextIndex = 0
    private var awaiting = false
    private var terminal: Step?

    public init(frames: [Data]) {
        self.frames = frames
    }

    public var frameCount: Int { frames.count }

    public var isTerminal: Bool { terminal != nil }

    /// Index of the frame waiting for confirmation.
    public var inFlightIndex: Int { max(0, nextIndex - 1) }

    /// Starts the set (or, after a confirmation, asks for the next step).
    public mutating func advance() -> Step {
        if let terminal { return terminal }
        guard !awaiting else { return .send(frames[inFlightIndex]) }
        guard nextIndex < frames.count else {
            terminal = .finished
            return .finished
        }
        let frame = frames[nextIndex]
        nextIndex += 1
        awaiting = true
        return .send(frame)
    }

    /// The platform confirmed (or refused) the frame in flight.
    public mutating func confirmed(success: Bool) -> Step {
        if let terminal { return terminal }
        guard awaiting else { return advance() }
        awaiting = false
        if success { return advance() }
        return fail(.rejected)
    }

    /// The frame in flight was not confirmed in time.
    public mutating func timedOut(reason: MeshFrameFailure = .timeout) -> Step {
        if let terminal { return terminal }
        return fail(reason)
    }

    /// The link went away under the set.
    public mutating func linkLost() -> Step {
        if let terminal { return terminal }
        return fail(.linkLost)
    }

    private mutating func fail(_ reason: MeshFrameFailure) -> Step {
        awaiting = false
        let step = Step.failed(reason, frameIndex: inFlightIndex)
        terminal = step
        return step
    }
}
