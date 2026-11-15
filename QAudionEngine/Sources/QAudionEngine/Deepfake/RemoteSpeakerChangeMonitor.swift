import Foundation

/// Turns `SpeakerChangeDetector`'s output into the single tri-state the call
/// UI shows.
///
/// 2026-08-29 port of Android's
/// `analysis/speakerchange/RemoteSpeakerChangeMonitor.kt`.
///
/// ## What this signals, and what it deliberately does not
///
/// It signals one fact: the voice arriving from the far end is no longer the
/// voice that was arriving a moment ago in this call. It is informational —
/// it never mutes a microphone, ends a call, blocks a key exchange or asks
/// the user to confirm anything, so the cost of being wrong is a badge
/// changing colour, which is what allows the operating point to favour
/// reacting quickly.
///
/// It is not an identity claim. "Different from before" and "not the contact
/// you think you are talking to" are different statements, and only the
/// second needs impostor-calibrated absolute scoring, which this system does
/// not yet have.
public final class RemoteSpeakerChangeMonitor: @unchecked Sendable {

    public enum Level: String { case unknown, steady, suspect, changed }

    public struct Verdict: Equatable {
        public let level: Level

        public init(level: Level) {
            self.level = level
        }
    }

    /// Fires on the caller's thread whenever the verdict actually changes.
    public var onVerdictChanged: ((Verdict) -> Void)?

    public private(set) var verdict = Verdict(level: .unknown)

    private let detector: SpeakerChangeDetector
    private let lock = NSLock()

    public init(detector: SpeakerChangeDetector = SpeakerChangeDetector()) {
        self.detector = detector
    }

    /// Feed one verification score for the far end's voice. `nil` is a
    /// genuine no-op — see `SpeakerChangeDetector.feed`.
    public func feed(_ score: Float?) {
        // Under the lock, like `reanchor` and `reset`: a path change can
        // re-anchor from another thread while a scoring tick feeds.
        lock.lock()
        let evaluation = detector.feed(score)
        lock.unlock()
        guard let evaluation else { return }
        publish(Self.verdict(for: evaluation.state))
    }

    /// Re-anchor on whoever is speaking now, so a second handover — most
    /// often the handset going back — is detectable rather than hidden
    /// behind a latched verdict.
    public func reanchor() {
        lock.lock()
        detector.reanchor()
        lock.unlock()
    }

    /// New call, or a new contact template.
    public func reset() {
        lock.lock()
        detector.reset()
        lock.unlock()
        publish(Verdict(level: .unknown))
    }

    // MARK: - Internals

    static func verdict(for detectorState: SpeakerChangeDetector.State) -> Verdict {
        switch detectorState {
        case .unknown: return Verdict(level: .unknown)
        case .steady: return Verdict(level: .steady)
        case .suspect: return Verdict(level: .suspect)
        case .changed: return Verdict(level: .changed)
        }
    }

    private func publish(_ next: Verdict) {
        lock.lock()
        let changed = next != verdict
        if changed { verdict = next }
        lock.unlock()
        if changed { onVerdictChanged?(next) }
    }
}
