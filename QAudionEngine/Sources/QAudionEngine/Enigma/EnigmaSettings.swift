import Foundation

/// Where the Enigma mode setting and its remote flag live. Pure and injectable (a UserDefaults suite and the flag value
/// are parameters) so the rules run on the test lane.
///
/// The server flag is `enigma_mode.enabled`, the same key Android reads. It is a kill switch: the feature ships ON (the
/// compiled default below) and the flag file may only switch it OFF, never turn on a build compiled with it off. The user's
/// own choice is stored as 0 off, 1 lite, 2 full under `levelKey` and starts at off. While the flag is off the effective
/// choice is off whatever is stored, and the setting is not offered.
public enum EnigmaSettings {
    public static let flagKey = "enigma_mode.enabled"
    public static let flagDefault = true
    public static let levelKey = "qaudion.chat.enigma_level"

    /// The stored choice (off when nothing was ever stored).
    public static func storedLevel(defaults: UserDefaults = .standard) -> EnigmaLevel {
        EnigmaLevel.fromStored(defaults.integer(forKey: levelKey))
    }

    public static func setStoredLevel(_ level: EnigmaLevel, defaults: UserDefaults = .standard) {
        defaults.set(level.rawValue, forKey: levelKey)
    }

    /// The user's level as the effect sees it: off whenever the flag is off.
    public static func userLevel(flagOn: Bool, defaults: UserDefaults = .standard) -> EnigmaLevel {
        flagOn ? storedLevel(defaults: defaults) : .off
    }
}
