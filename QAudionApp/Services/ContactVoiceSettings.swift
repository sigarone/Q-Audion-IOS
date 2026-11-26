import Foundation
import QAudionEngine

/// The owner setting of the contact-voice check and its entitlement, in ONE place for the whole app: the settings screen, the
/// contact screen and the call all read it here.
///
/// Availability follows the voice-biometrics entitlement, fail closed: a verified grant that carries the capability is needed, and
/// "nothing loaded yet" counts as not entitled. Deletion never depends on it (`ContactVoiceOwnerSetting.ui`).
enum ContactVoiceSettings {
    static let shared = ContactVoiceOwnerSetting(
        pref: UserDefaultsContactVoiceOwnerPref(),
        entitled: { entitledNow() },
        featureOn: { VoiceCallWiring.isEnabled },
        wipeAll: { VoiceCallWiring.ownerTurnedOff() })

    /// The entitlement is main-actor state; a worker waits for the answer, the main thread never waits for a worker.
    static func entitledNow() -> Bool {
        let read: () -> Bool = { MainActor.assumeIsolated { AppState.shared.capabilityGate.has(.voiceBiometrics) } }
        if Thread.isMainThread { return read() }
        return DispatchQueue.main.sync(execute: read)
    }

    /// The enrolled voice template of the owner, read only; the engine uses it for a diagnostic counter and never in a decision.
    static func ownerTemplate() -> [Float]? {
        VoiceprintStore().load(contactId: VoiceprintStore.deviceOwnerId)
    }
}
