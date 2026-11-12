import Foundation

/// One serial queue for the work that touches the audio session and the audio engine during a
/// call: the native audio unit switch, the route preflight, `AudioCapture.start()` and
/// `AudioCapture.stop()`. The caller's thread (main) only submits a request and receives the
/// result.
///
/// Why one queue for start AND stop: the engine objects have no thread-safety guarantee, so a
/// stop must not run on another thread while a start is still building the engine (see
/// `CallKitWorkOffloadPolicy.voiceProcessingTeardownQueueEnabled`).
/// Here a stop waits behind the start that is running, so the two run one after the other, and a start
/// that has not begun when a stop is submitted is skipped, so no engine is left running after
/// the stop.
///
/// Epochs: `submitStop` and `invalidatePendingStarts` bump the epoch synchronously on the
/// calling thread. A start carries the epoch read when it was submitted and runs only if that
/// epoch is still current when its turn comes.
public final class AudioEngineSerialQueue: @unchecked Sendable {

    /// The queue of the calls. Every `CallService` audio operation goes through it.
    public static let shared = AudioEngineSerialQueue(label: "com.qaudion.callservice.audioengine")

    private let queue: DispatchQueue
    private let lock = NSLock()
    private var epoch = 0

    public init(label: String, qos: DispatchQoS = .userInitiated) {
        queue = DispatchQueue(label: label, qos: qos)
    }

    public var currentEpoch: Int {
        lock.lock()
        defer { lock.unlock() }
        return epoch
    }

    /// Makes every start submitted so far stale. Returns the new epoch.
    @discardableResult
    public func invalidatePendingStarts() -> Int {
        lock.lock()
        defer { lock.unlock() }
        epoch += 1
        return epoch
    }

    /// Queues `work` behind everything submitted before. It runs only while `epoch` is still the
    /// current one; otherwise `skipped` runs in its place (also on the queue).
    public func submitStart(
        epoch startEpoch: Int,
        work: @escaping () -> Void,
        skipped: @escaping () -> Void = {}
    ) {
        queue.async { [self] in
            if currentEpoch == startEpoch {
                work()
            } else {
                skipped()
            }
        }
    }

    /// Queues `work` behind everything submitted before and makes the starts queued so far stale.
    /// The work always runs.
    public func submitStop(_ work: @escaping () -> Void) {
        invalidatePendingStarts()
        queue.async(execute: work)
    }

    /// Returns once everything submitted before this call has run. For tests: never call it from
    /// a thread the queued work waits on.
    public func waitUntilIdle() {
        queue.sync {}
    }
}
