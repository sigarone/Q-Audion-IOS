import Foundation

public struct OnboardingFlowViewModel: ViewModelProtocol {

    public enum Step: Equatable, Sendable {
        case welcome
        case authChoice            // register vs login
        case register
        case login
        case recoverySetup         // enroll mnemonic
        case done

        fileprivate var rank: Int {
            switch self {
            case .welcome: return 0
            case .authChoice: return 1
            case .register, .login: return 2
            case .recoverySetup: return 3
            case .done: return 4
            }
        }
    }

    public let step: Step
    public let canSkipRecovery: Bool
    /// User chose to skip recovery (warned). Tracked so we can re-prompt later.
    public let skippedRecovery: Bool

    public init(step: Step, canSkipRecovery: Bool = true,
                skippedRecovery: Bool = false) {
        self.step = step
        self.canSkipRecovery = canSkipRecovery
        self.skippedRecovery = skippedRecovery
    }

    public func advancing(to next: Step) -> OnboardingFlowViewModel {
        guard next.rank >= step.rank else { return self }  // forward-only
        return OnboardingFlowViewModel(
            step: next,
            canSkipRecovery: canSkipRecovery,
            skippedRecovery: skippedRecovery
        )
    }

    public func markingSkipped(recovery: Bool = false) -> OnboardingFlowViewModel {
        OnboardingFlowViewModel(
            step: step,
            canSkipRecovery: canSkipRecovery,
            skippedRecovery: skippedRecovery || recovery
        )
    }

    public static let mock = OnboardingFlowViewModel(step: .welcome)
}
