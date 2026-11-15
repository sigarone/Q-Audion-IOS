import Foundation

/// One-time removal of the contact voice templates that earlier versions kept
/// in the Keychain next to the owner's own. Nothing reads or writes them any
/// more, and they are not carried over.
///
/// It deletes every template of the voiceprint store except the device
/// owner's (`VoiceprintStore.deviceOwnerId`), and their entries in the store's
/// list of ids. The owner's own template is not touched.
///
/// The mark that the removal is done lives in the app's own defaults. A
/// reinstall removes the defaults but not the Keychain, so on a reinstall the
/// mark is absent and the removal runs again, as on the first launch of the
/// version that has it. The removal waits for an unlocked phone, and the mark
/// is set only when it ran to the end with the phone still unlocked: a
/// Keychain that cannot be read, or a phone that locked during the run, leaves
/// it unset, and the next start or unlock tries again.
public enum LegacyContactVoiceCleanup {
    static let doneKey = "voice.legacyContactCleanup.v1"

    /// Runs the removal unless it is already done on this install. Returns
    /// `true` when it ran to the end in this call.
    @discardableResult
    public static func runIfNeeded(store: VoiceprintStore = VoiceprintStore(),
                                   defaults: UserDefaults = .standard,
                                   protectedData: ProtectedDataFlag = .shared) -> Bool {
        if defaults.bool(forKey: doneKey) { return false }
        guard protectedData.isAvailable else { return false }
        guard store.deleteAllContactTemplates() else { return false }
        // The Keychain listing leaves out the items that are unavailable while the phone is locked, so a run
        // during which it locked may be incomplete: it is not marked done.
        guard protectedData.isAvailable else { return false }
        defaults.set(true, forKey: doneKey)
        return true
    }
}
