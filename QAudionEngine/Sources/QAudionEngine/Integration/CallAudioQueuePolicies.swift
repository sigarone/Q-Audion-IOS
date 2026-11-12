import Foundation

/// Pure decisions around the call audio queue (`AudioEngineSerialQueue`); the callers own the
/// queue and the engine.

/// What the playout path (main thread) may do with the engine objects.
public enum PlayoutEngineAccess {
    public enum Decision: Equatable {
        case schedule
        /// Drop the frame and touch nothing: the audio queue holds the engine, or it is not running.
        case drop
    }

    /// `lockAcquired` is the result of a non-blocking `try`-lock of the engine lock: when it is
    /// false the audio queue is starting, stopping or restarting the engine, and no engine object
    /// is read or used.
    public static func decision(
        lockAcquired: Bool, isRunning: Bool, hasPlayerAndEngine: Bool, engineRunning: Bool
    ) -> Decision {
        guard lockAcquired else { return .drop }
        return (isRunning && hasPlayerAndEngine && engineRunning) ? .schedule : .drop
    }
}

/// Whether a queued capture stop may deactivate the shared audio session. A stop that was
/// submitted for a call that has since been replaced by another one (back-to-back calls, no CallKit)
/// must not deactivate the session the new call already configured.
public enum CaptureStopPolicy {
    public static func shouldDeactivateSession(
        requested: Bool, submittedGeneration: Int, currentGeneration: Int
    ) -> Bool {
        requested && submittedGeneration == currentGeneration
    }
}

/// What to do with a fallback engage whose queued unit switch was skipped (another stop bumped the
/// epoch first): it is neither left half done nor repeated forever.
public enum FallbackEngageSkipPolicy {
    public enum Action: Equatable {
        /// The fallback no longer applies (recovered, ended, another engage): nothing to do.
        case drop
        /// Queue the unit switch again.
        case requeue
        /// Too many skips: give the call back to the native sender.
        case handBack
    }

    public static let maxRequeues = 3

    public static func action(stillCurrent: Bool, requeuesSoFar: Int) -> Action {
        guard stillCurrent else { return .drop }
        return requeuesSoFar < maxRequeues ? .requeue : .handBack
    }
}

/// Whether an audio-session interruption notification is still worth handling once it reaches the audio
/// queue: the capture's observer is still registered (a stop removes it) and no stop or end of call was
/// submitted since the notification was observed.
public enum InterruptionHandlingGuard {
    public static func shouldHandle(observerActive: Bool, observedEpoch: Int, currentEpoch: Int) -> Bool {
        observerActive && observedEpoch == currentEpoch
    }
}
