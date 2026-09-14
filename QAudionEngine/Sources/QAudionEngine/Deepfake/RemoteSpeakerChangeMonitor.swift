import Foundation

/// Turns `SpeakerChangeDetector`'s output into the single tri-state the call
/// UI shows, and folds in what the far end reports about itself.
///
/// 2026-08-29 port of Android's
/// `analysis/speakerchange/RemoteSpeakerChangeMonitor.kt`.
///
/// ## What this signals, and what it deliberately does not
///
/// It signals one fact: the voice arriving from the far end is no longer the
/// voice that was arriving a moment ago. It is informational — it never
/// mutes a microphone, ends a call, blocks a key exchange or asks the user
/// to confirm anything, so the cost of being wrong is a badge changing
/// colour, which is what allows the operating point to favour reacting
/// quickly.
///
/// It is not an identity claim. "Different from before" and "not the contact
/// you think you are talking to" are different statements, and only the
/// second needs impostor-calibrated absolute scoring, which this system does
/// not yet have.
///
/// ## Symmetry
///
/// One receive-side detector covers both directions without extra
/// machinery. If the far end passes their handset to someone else, this
/// device hears a new voice and detects it; if the local user passes theirs,
/// the far end's copy of this same class detects it there.
///
/// ## What the peer signal adds
///
/// `onPeerReportedChange` carries the far end's own receive-side verdict
/// about us. It corroborates — two detectors on different audio and
/// different devices agreeing is far stronger evidence than one — and, more
/// importantly, it is the only signal available to the user who just handed
/// their own phone over, whose device hears no change at all.
///
/// A peer report can never by itself raise the verdict above `.suspect`. The
/// far end's device is outside this device's trust boundary; it is the party
/// a coerced or substituted speaker would be operating, so its claim informs
/// the display and never decides it.
public final class RemoteSpeakerChangeMonitor: @unchecked Sendable {

    public enum Level: String { case unknown, steady, suspect, changed }

    public struct Verdict: Equatable {
        public let level: Level
        /// The far end independently reported a change at about the same time.
        public let corroborated: Bool
        /// The only evidence is the far end's report — this device heard
        /// nothing unusual, which is the case for the user who just handed
        /// their phone over. The wording shown must differ accordingly.
        public let peerReportedOnly: Bool

        public init(level: Level, corroborated: Bool = false, peerReportedOnly: Bool = false) {
            self.level = level
            self.corroborated = corroborated
            self.peerReportedOnly = peerReportedOnly
        }
    }

    /// Fires on the caller's thread whenever the verdict actually changes.
    public var onVerdictChanged: ((Verdict) -> Void)?

    public private(set) var verdict = Verdict(level: .unknown)

    private let detector: SpeakerChangeDetector
    private let lock = NSLock()
    private var peerReportsChange = false

    public init(detector: SpeakerChangeDetector = SpeakerChangeDetector()) {
        self.detector = detector
    }

    /// Feed one verification score for the far end's voice. `nil` is a
    /// genuine no-op — see `SpeakerChangeDetector.feed`.
    public func feed(_ score: Float?) {
        guard let evaluation = detector.feed(score) else { return }
        lock.lock()
        let next = fuse(evaluation.state)
        lock.unlock()
        publish(next)
    }

    /// Record the far end's own receive-side verdict about this device's user.
    public func onPeerReportedChange(_ changed: Bool) {
        lock.lock()
        guard peerReportsChange != changed else { lock.unlock(); return }
        peerReportsChange = changed
        let next = fuse(detector.state)
        lock.unlock()
        publish(next)
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
        peerReportsChange = false
        lock.unlock()
        publish(Verdict(level: .unknown))
    }

    // MARK: - Internals

    /// Must be called with `lock` held.
    private func fuse(_ detectorState: SpeakerChangeDetector.State) -> Verdict {
        let local: Level
        switch detectorState {
        case .unknown: local = .unknown
        case .steady: local = .steady
        case .suspect: local = .suspect
        case .changed: local = .changed
        }

        if local == .changed {
            return Verdict(level: .changed, corroborated: peerReportsChange)
        }
        if local == .suspect {
            return Verdict(level: .suspect, corroborated: peerReportsChange)
        }
        if peerReportsChange {
            // Capped on purpose: an unverifiable claim from outside the trust
            // boundary informs the display, it does not decide it.
            return Verdict(level: .suspect, corroborated: false, peerReportedOnly: true)
        }
        return Verdict(level: local)
    }

    private func publish(_ next: Verdict) {
        lock.lock()
        let changed = next != verdict
        if changed { verdict = next }
        lock.unlock()
        if changed { onVerdictChanged?(next) }
    }
}
