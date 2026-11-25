import Foundation

/// What the owner sees of one learned voice: the state of the record and, for a voice still being learned, the progress as net
/// speech, sessions and days. The values come from the record only (never from the contact database); nothing here leaves the phone.
public struct ContactVoiceSummary: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case learning
        case partlyLearned
        case learned
        case mayHaveChanged
    }

    public let kind: Kind
    /// Net speech so far, in seconds, never above `targetS`.
    public let speechS: Int
    /// The net speech that a learned voice needs, in seconds.
    public let targetS: Int
    public let sessions: Int
    public let days: Int
    /// When the record became learned (unix seconds), 0 while it has not.
    public let enrolledS: Int

    public init(kind: Kind, speechS: Int, targetS: Int, sessions: Int, days: Int, enrolledS: Int) {
        self.kind = kind
        self.speechS = speechS
        self.targetS = targetS
        self.sessions = sessions
        self.days = days
        self.enrolledS = enrolledS
    }

    /// True when "Relearn" is offered (a voice that may have changed only).
    public var canRelearn: Bool { kind == .mayHaveChanged }

    static func of(_ rec: TemplateRecord, _ cfg: VoiceStateConstants) -> ContactVoiceSummary {
        let consensus = rec.sessions.filter { $0.inConsensus }
        let counted = consensus.isEmpty ? rec.sessions : consensus
        let speechMs = rec.consensusSpeechMs > 0 ? rec.consensusSpeechMs : counted.reduce(0) { $0 + $1.speechMs }
        let target = cfg.enroll.enrMs / 1000
        let kind: Kind
        switch rec.state {
        case TemplateState.provisional: kind = .partlyLearned
        case TemplateState.enrolled: kind = .learned
        case TemplateState.needsRefresh: kind = .mayHaveChanged
        default: kind = .learning
        }
        return ContactVoiceSummary(
            kind: kind, speechS: min(speechMs / 1000, target), targetS: target, sessions: counted.count,
            days: Set(counted.map { $0.dayIndex }).count, enrolledS: rec.enrolledS)
    }
}
