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

    /// Whether the call screens show this monitor's verdict. Off: the monitor and its detector run as
    /// always and every change of level is logged (`transitionLine`), but nothing of the verdict is
    /// drawn, announced or sent: no card, no shield, no popup. The call screens read it through
    /// `VoiceGuard`, and `AppState` publishes the verdict only while it is on.
    public static let verdictShownToUser: Bool = false

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
    /// Scores that reached the detector since the last `reset()`. Only for the log line.
    private var scoreCount = 0
    /// Where the transition line goes: the standard output, which the app's log tee ships.
    private let log: (String) -> Void

    public convenience init(detector: SpeakerChangeDetector = SpeakerChangeDetector()) {
        self.init(detector: detector, log: { print($0) })
    }

    /// Same as the public initializer with the destination of the transition line injected (tests).
    init(detector: SpeakerChangeDetector, log: @escaping (String) -> Void) {
        self.detector = detector
        self.log = log
    }

    /// Feed one verification score for the far end's voice. `nil` is a
    /// genuine no-op — see `SpeakerChangeDetector.feed`.
    public func feed(_ score: Float?) {
        // Under the lock, like `reanchor` and `reset`: a path change can
        // re-anchor from another thread while a scoring tick feeds.
        lock.lock()
        let evaluation = detector.feed(score)
        if evaluation != nil { scoreCount += 1 }
        let scores = scoreCount
        lock.unlock()
        guard let evaluation else { return }
        publish(Self.verdict(for: evaluation.state)) { level in
            Self.transitionLine(level: level, scores: scores,
                                reference: evaluation.referenceMedian,
                                deviation: evaluation.referenceSigma,
                                last: evaluation.score)
        }
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
        scoreCount = 0
        lock.unlock()
        publish(Verdict(level: .unknown)) { level in
            Self.transitionLine(level: level, scores: 0, reference: nil, deviation: nil, last: nil)
        }
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

    /// The one log line of a level change: level code (0 unknown, 1 steady, 2 suspect, 3 changed),
    /// scores seen so far, then the reference centre and deviation of the detector (absent while it has
    /// none) and the last score, all plain numbers: "[Voice] change lv=1 n=7 base=0.63 sd=0.05 cur=0.58".
    /// The words are ones the phone-log shipper admits; the shape is pinned in
    /// `scripts/test_ship_ios_display_vocab.py` (keep both in sync).
    static func transitionLine(level: Level, scores: Int, reference: Float?, deviation: Float?,
                               last: Float?) -> String {
        let code: Int
        switch level {
        case .unknown: code = 0
        case .steady:  code = 1
        case .suspect: code = 2
        case .changed: code = 3
        }
        var line = "[Voice] change lv=\(code) n=\(scores)"
        if let reference { line += " base=" + String(format: "%.2f", Double(reference)) }
        if let deviation { line += " sd=" + String(format: "%.2f", Double(deviation)) }
        if let last { line += " cur=" + String(format: "%.2f", Double(last)) }
        return line
    }

    /// Records the verdict and, only when its level actually changed, logs one line and notifies.
    private func publish(_ next: Verdict, line: (Level) -> String) {
        lock.lock()
        let changed = next != verdict
        if changed { verdict = next }
        lock.unlock()
        guard changed else { return }
        log(line(next.level))
        onVerdictChanged?(next)
    }
}
