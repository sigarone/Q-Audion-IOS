import Foundation

/// The state of the peer's device key pin.
enum TierPinState: String {
    case pinned
    case unpinned
    case identityChanged = "identity_changed"
    case unresolved
}

/// The authentication word of the call's SAS state: `H` and `C` count, `none` is tier 0.
enum TierAuthWord: String {
    case h = "H"
    case c = "C"
    case noWord = "none"
}

/// What the call knows about the peer's key at one moment (the platform-neutral input of the tier function).
/// `keyAgeS` is the age of the pin in seconds, -1 when unknown.
struct VoiceTierInput: Equatable {
    var pinState: TierPinState
    var keyAgeS: Int
    var viaLegacyRow: Bool
    var oobVerified: Bool
    var pinAnomaly: Bool
    var kcmacOk: Bool
    var heldUnresolved: Bool
    var authWord: TierAuthWord
}

/// The tier of one input: 0 when any tier-0 condition holds, 2 when it is not tier 0 and the key was verified out of band, 1
/// otherwise. Out-of-band verification never lifts a tier-0 condition. The tier of a call is the lowest tier of every moment at
/// which the inputs were evaluated (the engine keeps the minimum); a call with none evaluated is tier 0.
enum VoiceTier {
    /// 24 h: a code constant, not a bundle key (a bundle bump must not move it).
    static let minKeyAgeSeconds = 86_400

    static func tier(_ i: VoiceTierInput) -> Int {
        let zero = i.pinState != .pinned
            || i.viaLegacyRow
            || i.keyAgeS < minKeyAgeSeconds // also -1 (unknown) and any other negative age
            || i.pinAnomaly
            || !i.kcmacOk
            || i.heldUnresolved
            || i.authWord == .noWord
        if zero { return 0 }
        return i.oobVerified ? 2 : 1
    }
}
