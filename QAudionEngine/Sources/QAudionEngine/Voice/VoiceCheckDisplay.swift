import Foundation

/// What the voice card of the call screen shows, one state at a time. The app turns each into its words (the wording is in the
/// app); none of them says impostor, fake or fraud.
public enum VoiceCheckDisplay: Equatable, Sendable {
    /// The voice matches the one learned.
    case matches
    /// The voice is being checked.
    case checking
    /// The call is on a setup the voice was not learned on, so the voice is only being checked.
    case checkingDifferentSetup
    /// The voice sounds different from the one learned.
    case differs
    /// The same, from a device that earlier calls did not use.
    case differsNewDevice
    /// The check is off for this call.
    case off
    /// The voice cannot be checked right now (audio quality).
    case cannotVerify
    /// The voice of this contact is being learned.
    case learning
    /// The voice seems to have changed during the call (a contact that is not enrolled yet).
    case changed

    /// The state that a change of the shown state of the machine stands for.
    init(shown: VoiceShown, detail: VoiceDetail?) {
        switch shown {
        case .matches: self = .matches
        case .checking: self = detail == .differentSetup ? .checkingDifferentSetup : .checking
        case .differs: self = detail == .deviceNew ? .differsNewDevice : .differs
        case .off: self = .off
        case .cannotVerify: self = .cannotVerify
        case .learning: self = .learning
        case .changed: self = .changed
        }
    }
}
