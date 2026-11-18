import Foundation

/// What is known about this device's own screen capture, as a pure state machine: whether the capture is confirmed
/// running, and when it is over. It is driven by what the recorder reports and by a clock, never by the screen.
///
/// A capture is confirmed once its first frame has arrived. An end that comes in while the capture is still starting is
/// kept and handed out when the start completes, so it is not lost. A running capture ends when the recorder that was
/// recording stops, when a capture that never produced a frame stays silent, or when the recorder is not recording and no
/// frame has arrived for a while. Whether the screen is captured by anything is never asked: that state is global and is
/// also true for a recording or a mirror that is not ours, so it cannot keep this share alive. The recorder sends a frame
/// only when the screen changes, so silence while it reports recording is not an end.
struct ScreenShareLiveness {

    enum Phase: Equatable {
        /// Nothing is running.
        case idle
        /// The recorder was asked to start and has not answered yet.
        case starting
        /// The recorder started the capture.
        case running
        /// The capture is over and has not been torn down yet.
        case ended
    }

    enum EndReason: Equatable {
        /// The recorder reported an error.
        case error
        /// The recorder was recording and is not any more.
        case recorderStopped
        /// A capture that never produced a frame stayed silent.
        case noFirstFrame
        /// No frame arrived for a while and the recorder is not recording.
        case nothingCaptured
    }

    /// How long a capture may stay silent before that counts: from its start for a capture that never produced a
    /// frame, from its last frame for one whose screen is no longer captured.
    static let silenceLimit: TimeInterval = 3

    private(set) var phase: Phase = .idle
    /// True once the first frame of the running capture has arrived.
    private(set) var confirmed = false
    private var pendingEnd: EndReason?
    private var startedAt: TimeInterval = 0
    private var lastFrameAt: TimeInterval = 0
    /// True once the recorder has been seen recording during this capture: only a recorder that was recording can
    /// stop.
    private var sawRecording = false

    /// A capture starts.
    mutating func begin() {
        phase = .starting
        confirmed = false
        pendingEnd = nil
        sawRecording = false
    }

    /// The recorder answered the start. Returns the reason when the capture ended meanwhile (the recorder reported an
    /// error); the capture is then over.
    mutating func startCompleted(now: TimeInterval, isRecording: Bool) -> EndReason? {
        guard phase == .starting else { return nil }
        if let reason = pendingEnd {
            phase = .ended
            pendingEnd = nil
            return reason
        }
        phase = .running
        startedAt = now
        lastFrameAt = now
        sawRecording = isRecording
        return nil
    }

    /// The start itself failed.
    mutating func startFailed() {
        reset()
    }

    /// A frame arrived. Returns true for the first one of the capture: it is confirmed running.
    mutating func frame(now: TimeInterval) -> Bool {
        guard phase == .running else { return false }
        lastFrameAt = now
        guard !confirmed else { return false }
        confirmed = true
        return true
    }

    /// The recorder reported that the capture is over. Returns true when that has to be reported now: the capture was
    /// running. While it is starting the end is kept; in any other phase it is ignored.
    mutating func end(_ reason: EndReason) -> Bool {
        switch phase {
        case .starting:
            if pendingEnd == nil { pendingEnd = reason }
            return false
        case .running:
            phase = .ended
            confirmed = false
            return true
        case .idle, .ended:
            return false
        }
    }

    /// A look at the recorder. Returns the reason when the running capture is over.
    mutating func check(now: TimeInterval, isRecording: Bool) -> EndReason? {
        guard phase == .running else { return nil }
        if isRecording { sawRecording = true }
        let reason: EndReason?
        if !confirmed, now - startedAt >= Self.silenceLimit {
            reason = .noFirstFrame
        } else if !isRecording, sawRecording {
            reason = .recorderStopped
        } else if !isRecording, now - lastFrameAt >= Self.silenceLimit {
            reason = .nothingCaptured
        } else {
            reason = nil
        }
        guard let reason else { return nil }
        phase = .ended
        confirmed = false
        return reason
    }

    /// The capture was torn down.
    mutating func reset() {
        phase = .idle
        confirmed = false
        pendingEnd = nil
        sawRecording = false
    }

    /// True while a capture is starting or running.
    var isActive: Bool { phase == .starting || phase == .running }
}
