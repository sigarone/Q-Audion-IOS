import Foundation

/// What the video encode path does with a frame the encoder refused.
///
/// VideoToolbox invalidates a compression session when the app goes to the background, and every later frame is then
/// refused with the invalid-session status until the session is built again. The gate asks for that rebuild, at most
/// once per interval and only between `arm()` and `disarm()`, and says when a failure is worth a log line: the first
/// one of an episode (an episode ends with the next frame the encoder accepts).
public final class EncodeFailureGate: @unchecked Sendable {

    /// VideoToolbox `kVTInvalidSessionErr`.
    public static let invalidSessionStatus: Int32 = -12903
    /// The shortest time between two rebuilds.
    public static let minRecreateIntervalMs: Int64 = 1_000

    public struct Decision: Equatable, Sendable {
        public let recreate: Bool
        public let log: Bool
    }

    private let lock = NSLock()
    private var armed = false
    private var lastRecreateMs: Int64?
    private var inEpisode = false
    private var rebuildPending = false

    public init() {}

    /// The encoder is up: a refused frame may ask for a rebuild.
    public func arm() {
        lock.lock()
        armed = true
        lastRecreateMs = nil
        inEpisode = false
        rebuildPending = false
        lock.unlock()
    }

    /// The encoder is going away: nothing asks for a rebuild any more.
    public func disarm() {
        lock.lock()
        armed = false
        lock.unlock()
    }

    /// The encoder accepted a frame: the episode, if there was one, is over.
    public func noteSuccess() {
        lock.lock()
        inEpisode = false
        lock.unlock()
    }

    /// The outcome of the rebuild this gate asked for. While it failed, a later frame that finds no session asks again.
    public func noteRecreateResult(succeeded: Bool) {
        lock.lock()
        rebuildPending = !succeeded
        lock.unlock()
    }

    /// A frame was refused: whether to rebuild the session and whether to log.
    public func noteFailure(_ failure: Error, nowMs: Int64) -> Decision {
        var wantsRebuild = false
        if let encoderError = failure as? HevcEncoder.EncoderError {
            switch encoderError {
            case .encodeFailed(let status):
                wantsRebuild = status == Self.invalidSessionStatus
            case .sessionNotInitialised:
                lock.lock()
                wantsRebuild = rebuildPending
                lock.unlock()
            default:
                break
            }
        }
        lock.lock()
        defer { lock.unlock() }
        let log = !inEpisode
        inEpisode = true
        var recreate = false
        if armed, wantsRebuild {
            let due = lastRecreateMs.map { nowMs - $0 >= Self.minRecreateIntervalMs } ?? true
            if due {
                lastRecreateMs = nowMs
                recreate = true
            }
        }
        return Decision(recreate: recreate, log: log)
    }
}
