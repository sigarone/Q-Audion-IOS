import Foundation

public struct VoiceEnrollmentViewModel: ViewModelProtocol {

    public enum Step: Equatable, Sendable {
        case introduction              // explain the flow
        case promptShowing(prompt: String)  // current sentence the user must read
        case recording(prompt: String, secondsElapsed: Double)
        case processing                // post-recording analysis
        case complete(speakerEmbeddingId: String)
        case error(message: String)

        fileprivate var rank: Int {
            switch self {
            case .introduction: return 0
            case .promptShowing: return 1
            case .recording: return 2
            case .processing: return 3
            case .complete, .error: return 4
            }
        }
    }

    public let prompts: [String]
    public let currentPromptIndex: Int
    public private(set) var step: Step
    /// Live audio level 0…1 captured during .recording. Bind to a meter UI.
    public let audioLevel: Double
    /// Cumulative count of completed prompts (for progress indicator).
    public let completedPromptsCount: Int

    public var totalPrompts: Int { prompts.count }
    public var progressFraction: Double {
        guard totalPrompts > 0 else { return 0 }
        return Double(completedPromptsCount) / Double(totalPrompts)
    }

    public init(prompts: [String], currentPromptIndex: Int = 0,
                step: Step = .introduction, audioLevel: Double = 0,
                completedPromptsCount: Int = 0) {
        self.prompts = prompts
        self.currentPromptIndex = currentPromptIndex
        self.step = step
        self.audioLevel = audioLevel
        self.completedPromptsCount = completedPromptsCount
    }

    public mutating func transition(to next: Step) {
        switch (step, next) {
        case (.error, _), (.complete, _):
            // Allow restart from terminal states.
            step = next
        case (let cur, let nxt) where nxt.rank >= cur.rank:
            step = next
        default:
            break  // reject backward
        }
    }

    /// Italian short phrases — matches Android's 3-phrase design
    /// (`qaudion-android-new` VoiceEnrollmentScreen: "qaudion seven alpha" /
    /// "seven alpha qaudion" / "alpha qaudion seven"), translated so the
    /// spoken language matches the rest of this app's Italian UI. Replaces
    /// the former 5 hardcoded ENGLISH placeholder sentences, which never
    /// matched the surrounding Italian screen copy.
    public static let mock = VoiceEnrollmentViewModel(
        prompts: [
            "qaudion sette alpha",
            "sette alpha qaudion",
            "alpha qaudion sette"
        ],
        currentPromptIndex: 0,
        step: .introduction,
        audioLevel: 0,
        completedPromptsCount: 0
    )
}
