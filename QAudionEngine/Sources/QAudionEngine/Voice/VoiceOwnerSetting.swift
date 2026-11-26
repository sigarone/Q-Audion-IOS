import Foundation

/// Where the choice of the owner is kept: an ordinary local setting, outside the learner store, never sent anywhere.
public protocol ContactVoiceOwnerPref: AnyObject {
    /// The choice, or nil when none was ever made.
    var stored: Bool? { get }
    func write(_ on: Bool)
}

/// `UserDefaults` under one key.
public final class UserDefaultsContactVoiceOwnerPref: ContactVoiceOwnerPref {
    public static let key = "qaudion.contact_voice.recognise"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var stored: Bool? { defaults.object(forKey: Self.key) as? Bool }

    public func write(_ on: Bool) {
        defaults.set(on, forKey: Self.key)
    }
}

/// What the screens show of the contact-voice check.
public enum ContactVoiceUi: Equatable, Sendable {
    /// Nothing: the check is not available to this account and no learned voice exists.
    case hidden
    /// The toggle, the learned voices and the rows of the contacts.
    case full
    /// Only the way to delete: learned voices exist but the account is not entitled (or the feature is off). No toggle, no learning.
    case deleteOnly
}

/// The owner setting "Recognise my contacts voices" (default ON, no notice screen, no prompt) and the ONE place that decides whether
/// the check is available to this account.
///
/// Availability follows the voice-biometrics entitlement, fail closed (`entitled`): without a verified grant that carries the
/// capability nothing is processed, nothing is learned and there is no toggle; "nothing loaded yet" counts as not entitled.
/// Deletion never sits behind the entitlement: while any learned voice exists the list with "Delete all" and the "Forget this voice"
/// row stay reachable (`ui`), and nothing is deleted automatically when the entitlement is missing.
///
/// `ownerOn` is what a call reads once at its start: the flag, the choice AND the entitlement. Turning the choice off stores it first
/// and then deletes every learned voice, `meta.bin` and the key through `wipeAll` (it moves the wipe generation on before it deletes,
/// so a write that is still on its way cannot bring anything back). Turning it on again changes nothing else.
public final class ContactVoiceOwnerSetting: @unchecked Sendable {
    private let pref: ContactVoiceOwnerPref
    private let entitled: () -> Bool
    private let featureOn: () -> Bool
    private let wipeAll: () -> Bool

    public init(pref: ContactVoiceOwnerPref, entitled: @escaping () -> Bool, featureOn: @escaping () -> Bool, wipeAll: @escaping () -> Bool) {
        self.pref = pref
        self.entitled = entitled
        self.featureOn = featureOn
        self.wipeAll = wipeAll
    }

    /// The stored choice; true when none was ever made.
    public var choice: Bool { pref.stored ?? true }

    /// What a call reads at its start: the flag, the choice and the entitlement.
    public var ownerOn: Bool { featureOn() && choice && entitled() }

    /// True when the toggle and the rows of the contacts are available.
    public var available: Bool { featureOn() && entitled() }

    /// What the screens show, given whether any learned voice exists.
    public func ui(hasRecords: Bool) -> ContactVoiceUi {
        if available { return .full }
        return hasRecords ? .deleteOnly : .hidden
    }

    /// Stores the choice; off also deletes everything learned. Turning it on is refused (false, nothing stored) without the
    /// entitlement. False when the deletion left something (the choice stays off).
    @discardableResult
    public func setOn(_ on: Bool) -> Bool {
        if on {
            guard available else { return false }
            pref.write(true)
            return true
        }
        pref.write(false)
        return wipeAll()
    }
}
