import Foundation

/// Real-time security threat detector for the Q-Audion transport layer.
///
/// Monitors encrypted frame traffic for anomalies that may indicate an
/// active attack: replayed frames, injected out-of-order packets, timing
/// side-channels, and key reuse across sessions.
///
/// Integrates with `GuardianMode` through a shared alert callback.
public final class ThreatDetector: @unchecked Sendable {

    // MARK: - Threat classification

    /// Category of detected threat.
    public enum ThreatKind: String, Sendable {
        case replayAttack        = "replay_attack"
        case outOfOrderInjection = "out_of_order_injection"
        case timingAnomaly       = "timing_anomaly"
        case keyReuse            = "key_reuse"
        case frameRateAnomaly    = "frame_rate_anomaly"
        case sequenceGap         = "sequence_gap"
    }

    /// Severity of the threat.
    public enum Severity: Int, Comparable, Sendable {
        case info = 0
        case warning = 1
        case critical = 2
        public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// A single threat event.
    public struct ThreatEvent: Sendable {
        public let kind: ThreatKind
        public let severity: Severity
        public let detail: String
        public let timestamp: Date
    }

    /// Callback invoked when a threat is detected.
    public var onThreat: ((ThreatEvent) -> Void)?

    // MARK: - State

    private let lock = NSLock()

    // Replay window: bitmap of recently seen sequence numbers.
    private var seenSequences: Set<UInt32> = []
    private var highestSeq: UInt32 = 0

    // Timing analysis
    private var lastFrameTime: TimeInterval = 0
    private var frameTimes: [TimeInterval] = []
    private let maxFrameTimeHistory = 64

    // Frame rate tracking
    private var frameCountInWindow: Int = 0
    private var windowStart: TimeInterval = 0
    private var expectedFrameRate: Double = Double(1000 / CryptoConstants.frameDurationMs)

    // Key reuse detection: track (sessionId, epoch) pairs.
    private var knownKeyFingerprints: Set<String> = []

    // Cumulative stats
    private(set) var totalThreatsDetected: Int = 0

    public init() {}

    // MARK: - Frame inspection

    /// Inspect an incoming frame for threats.  Call this on every received
    /// frame **before** decryption to detect transport-layer attacks.
    ///
    /// - Parameters:
    ///   - sequenceNumber: The frame's monotonic sequence number.
    ///   - timestamp: The frame's declared timestamp (ms since epoch).
    ///   - receiveTime: Actual wall-clock time the frame arrived.
    public func inspect(sequenceNumber: UInt32,
                        timestamp: UInt64,
                        receiveTime: Date = Date()) {
        lock.lock(); defer { lock.unlock() }

        let now = receiveTime.timeIntervalSince1970

        // 1. Replay detection
        if seenSequences.contains(sequenceNumber) {
            emit(.replayAttack, .critical,
                 "Duplicate sequence number \(sequenceNumber)")
        } else {
            trackSequence(sequenceNumber)
        }

        // 2. Large sequence gap
        if sequenceNumber > highestSeq {
            let gap = sequenceNumber - highestSeq
            if gap > CryptoConstants.maxSequenceGap {
                emit(.sequenceGap, .warning,
                     "Sequence gap of \(gap) (expected incremental)")
            }
            highestSeq = sequenceNumber
        } else if highestSeq > 0 && highestSeq - sequenceNumber > CryptoConstants.replayWindowSize {
            emit(.outOfOrderInjection, .warning,
                 "Sequence \(sequenceNumber) far behind head \(highestSeq)")
        }

        // 3. Timing analysis
        if lastFrameTime > 0 {
            let delta = now - lastFrameTime
            frameTimes.append(delta)
            if frameTimes.count > maxFrameTimeHistory {
                frameTimes.removeFirst()
            }
            if delta > CryptoConstants.maxAcceptableJitter {
                emit(.timingAnomaly, .info,
                     "Frame jitter \(String(format: "%.3f", delta))s exceeds threshold")
            }
        }
        lastFrameTime = now

        // 4. Frame rate anomaly
        if windowStart == 0 { windowStart = now }
        frameCountInWindow += 1
        let windowDuration = now - windowStart
        if windowDuration >= 1.0 {
            let rate = Double(frameCountInWindow) / windowDuration
            let deviation = abs(rate - expectedFrameRate) / expectedFrameRate
            if deviation > 0.5 {
                emit(.frameRateAnomaly, .warning,
                     "Frame rate \(String(format: "%.1f", rate)) fps deviates " +
                     "\(String(format: "%.0f", deviation * 100))% from expected " +
                     "\(String(format: "%.0f", expectedFrameRate)) fps")
            }
            frameCountInWindow = 0
            windowStart = now
        }
    }

    // MARK: - Key reuse detection

    /// Record a key fingerprint for the current session.
    /// If the same fingerprint was used in a different session context, a
    /// key-reuse threat is raised.
    ///
    /// - Parameters:
    ///   - sessionId: The current session identifier.
    ///   - keyFingerprint: A hash of the frame key or chain key.
    public func recordKeyUsage(sessionId: Data, keyFingerprint: Data) {
        lock.lock(); defer { lock.unlock() }
        let id = (sessionId + keyFingerprint).base64EncodedString()
        let keyOnly = keyFingerprint.base64EncodedString()

        // Check if this exact key fingerprint was seen with a different session.
        let existingWithDifferentSession = knownKeyFingerprints.contains(where: {
            $0.hasSuffix(keyOnly) && !$0.hasPrefix(sessionId.base64EncodedString())
        })
        if existingWithDifferentSession {
            emit(.keyReuse, .critical,
                 "Key fingerprint reused across sessions")
        }
        knownKeyFingerprints.insert(id)

        // Cap the fingerprint cache size to prevent unbounded growth.
        if knownKeyFingerprints.count > 4096 {
            knownKeyFingerprints.removeFirst()
        }
    }

    // MARK: - Reset

    /// Clear all detection state (e.g., on new session establishment).
    public func reset() {
        lock.lock()
        seenSequences.removeAll()
        highestSeq = 0
        lastFrameTime = 0
        frameTimes.removeAll()
        frameCountInWindow = 0
        windowStart = 0
        knownKeyFingerprints.removeAll()
        totalThreatsDetected = 0
        lock.unlock()
    }

    // MARK: - Private

    private func trackSequence(_ seq: UInt32) {
        seenSequences.insert(seq)
        // Evict entries outside the replay window to bound memory.
        if seenSequences.count > CryptoConstants.replayWindowSize * 2 {
            let cutoff = highestSeq > UInt32(CryptoConstants.replayWindowSize)
                ? highestSeq - UInt32(CryptoConstants.replayWindowSize) : 0
            seenSequences = seenSequences.filter { $0 >= cutoff }
        }
    }

    private func emit(_ kind: ThreatKind, _ severity: Severity, _ detail: String) {
        totalThreatsDetected += 1
        let event = ThreatEvent(kind: kind, severity: severity,
                                detail: detail, timestamp: Date())
        let callback = onThreat
        DispatchQueue.global(qos: .utility).async { callback?(event) }
    }
}
