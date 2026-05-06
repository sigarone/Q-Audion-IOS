import Foundation

public struct OnboardingFlowViewModel: ViewModelProtocol {

    public enum Step: Equatable, Sendable {
        case welcome
        case authChoice            // register vs login
        case register
        case login
        case recoverySetup         // enroll mnemonic
        case voiceEnrollment       // record voice
        case done

        fileprivate var rank: Int {
            switch self {
            case .welcome: return 0
            case .authChoice: return 1
            case .register, .login: return 2
            case .recoverySetup: return 3
            case .voiceEnrollment: return 4
            case .done: return 5
            }
        }
    }

    public let step: Step
    public let canSkipRecovery: Bool
    public let canSkipVoice: Bool
    /// User chose to skip recovery (warned). Tracked so we can re-prompt later.
    public let skippedRecovery: Bool
    public let skippedVoice: Bool

    public init(step: Step, canSkipRecovery: Bool = true, canSkipVoice: Bool = true,
                skippedRecovery: Bool = false, skippedVoice: Bool = false) {
        self.step = step
        self.canSkipRecovery = canSkipRecovery
        self.canSkipVoice = canSkipVoice
        self.skippedRecovery = skippedRecovery
        self.skippedVoice = skippedVoice
    }

    public func advancing(to next: Step) -> OnboardingFlowViewModel {
        guard next.rank >= step.rank else { return self }  // forward-only
        return OnboardingFlowViewModel(
            step: next,
            canSkipRecovery: canSkipRecovery,
            canSkipVoice: canSkipVoice,
            skippedRecovery: skippedRecovery,
            skippedVoice: skippedVoice
        )
    }

    public func markingSkipped(recovery: Bool = false, voice: Bool = false) -> OnboardingFlowViewModel {
        OnboardingFlowViewModel(
            step: step,
            canSkipRecovery: canSkipRecovery,
            canSkipVoice: canSkipVoice,
            skippedRecovery: skippedRecovery || recovery,
            skippedVoice: skippedVoice || voice
        )
    }

    public static let mock = OnboardingFlowViewModel(step: .welcome)
}
