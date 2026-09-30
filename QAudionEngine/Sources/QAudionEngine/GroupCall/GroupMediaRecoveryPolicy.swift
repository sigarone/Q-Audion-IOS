import Foundation

/// Group calls v2 (spec §2.4 / §2.5 / §4.7 / §8) — what the controller does
/// when the media path breaks or the server refuses it. Pure state machine:
/// the triggers come in, one `Action` comes out, time is passed in.
///
/// Principles (there is NO relay fallback any more):
///  * a security failure (DTLS pin, transport policy) ends the media at once;
///  * a Janus error the policy calls retryable gets ONE automatic
///    `group_call_media_rejoin` (the Janus session it happened on is unusable, and a plain
///    join could hit Janus 436 while the old participant is still in the room), then an
///    error;
///  * connection loss asks the server for a `group_call_media_rejoin` with a
///    short backoff (0.5 / 1 / 2 s), at most three times inside a minute, and
///    the counter is forgiven once the media has been stable for 30 s;
///  * `throttled` (the server rate-limits repeated joins) is waited out;
///  * everything else the server says is shown as a clear error.
public struct GroupMediaRecoveryPolicy: Sendable {

    public enum Trigger: Equatable, Sendable {
        /// `GroupMediaSession.Event.needsRejoin(reason)`.
        case needsRejoin(String)
        /// A Janus error the error policy marked `retryMediaJoin`.
        case retryableJanusError(Int)
        /// A Janus error that is not retryable.
        case fatalJanusError(Int)
        /// The session refused the path: pin mismatch or transport policy.
        case securityFailure
        case mediaUnavailable(GroupCallWire.UnavailableReason)
        /// `group_call_media_moved`: the room moved to another node.
        case mediaMoved
    }

    public enum Action: Equatable, Sendable {
        /// Send `group_call_media_join` after `delayMs`.
        case sendMediaJoin(delayMs: Int64)
        /// Send `group_call_media_rejoin(reason)` after `delayMs`.
        case sendMediaRejoin(reason: String, delayMs: Int64)
        /// Show this error and end the media.
        case fail(GroupCallMediaError)
    }

    public struct Config: Sendable {
        public var rejoinBackoffMs: [Int64] = [500, 1_000, 2_000]
        public var rejoinWindowMs: Int64 = 60_000
        public var stableAfterMs: Int64 = 30_000
        public var throttledDelayMs: Int64 = 2_000
        public var throttledMaxRetries = 3
        public var movedMax = 5

        public init() {}
    }

    public let config: Config
    private var rejoinTimes: [Int64] = []
    private var retriedJanusError = false
    private var throttledRetries = 0
    private var movedCount = 0
    private var activeSinceMs: Int64?

    public init(config: Config = Config()) {
        self.config = config
    }

    /// The media is up (both PeerConnections connected). The retry budgets
    /// reset once it has stayed up for `stableAfterMs`.
    public mutating func mediaBecameActive(nowMs: Int64) {
        if activeSinceMs == nil { activeSinceMs = nowMs }
    }

    public mutating func mediaWentDown() {
        activeSinceMs = nil
    }

    public mutating func handle(_ trigger: Trigger, nowMs: Int64) -> Action {
        if let since = activeSinceMs, nowMs - since >= config.stableAfterMs {
            rejoinTimes.removeAll()
            retriedJanusError = false
            throttledRetries = 0
            movedCount = 0
        }
        activeSinceMs = nil
        switch trigger {
        case .securityFailure:
            return .fail(.transportPolicy)

        case .fatalJanusError(let code):
            // 432: the room is full (VideoRoom `publishers` cap), the same thing the
            // server's `group_call_media_unavailable` reason `full` says.
            if code == 432 { return .fail(.full) }
            return .fail(.other("janus_\(code)"))

        case .retryableJanusError(let code):
            if retriedJanusError { return .fail(.mediaLost) }
            retriedJanusError = true
            return .sendMediaRejoin(reason: "janus_\(code)", delayMs: 0)

        case .needsRejoin(let reason):
            rejoinTimes.removeAll { nowMs - $0 > config.rejoinWindowMs }
            guard rejoinTimes.count < config.rejoinBackoffMs.count else { return .fail(.mediaLost) }
            let delay = config.rejoinBackoffMs[rejoinTimes.count]
            rejoinTimes.append(nowMs)
            return .sendMediaRejoin(reason: reason, delayMs: delay)

        case .mediaMoved:
            movedCount += 1
            if movedCount > config.movedMax { return .fail(.mediaLost) }
            return .sendMediaJoin(delayMs: 0)

        case .mediaUnavailable(let reason):
            switch reason {
            case .throttled:
                throttledRetries += 1
                if throttledRetries > config.throttledMaxRetries { return .fail(.mediaLost) }
                return .sendMediaJoin(delayMs: config.throttledDelayMs)
            case .noNode: return .fail(.noNode)
            case .roomCreateFailed: return .fail(.roomCreateFailed)
            case .notMember: return .fail(.notMember)
            case .full: return .fail(.full)
            case .other(let code): return .fail(.other(code))
            }
        }
    }
}

/// What the user is told when the media of a group call cannot be established
/// or kept. Maps 1:1 onto a localized message in the view layer.
public enum GroupCallMediaError: Equatable, Sendable {
    case noNode
    case roomCreateFailed
    case full
    case notMember
    /// DTLS pin mismatch or a transport below the required level.
    case transportPolicy
    case mediaLost
    case cameraPermissionDenied
    case cameraUnavailable
    case other(String)

    /// Fatal errors end the media (and the call); a camera problem does not.
    public var isFatal: Bool {
        switch self {
        case .cameraPermissionDenied, .cameraUnavailable: return false
        default: return true
        }
    }
}
