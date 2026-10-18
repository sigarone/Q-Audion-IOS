import Foundation
import QAudionEngine

/// W411 — single source of truth for transport-layer policy gates.
///
/// Before W411, TransportSettingsScreen persisted Mode + preferredTurn
/// values in SettingsStore that no production code path consumed. The
/// WebRTC bridge always fetched the default relay pool and used the
/// stock RTCConfiguration with `iceTransportPolicy = .all`.
///
/// W411 publishes these two values via UserDefaults so the WebRTC
/// controller can read them at peer-connection creation time. What each
/// mode then does is decided by the engine's `TransportPlan` (policy, which
/// servers, whether the WSS bridge), the same function the transport check
/// of the Settings screen uses; this type only stores and reads
/// (`TransportPreferences`, in the engine, so the storage is unit-tested).
///
/// The mode and the address of a custom TURN server are in UserDefaults; its
/// user name and password are in the Keychain (`TransportPreferences` has the
/// details). `credentialStore` is where they go: the Keychain in the app, an
/// in-memory store in a test.
public enum TransportGate {

    public static let keyPreferredTurnUrl = TransportPreferences.keyPreferredTurnUrl
    public static let keyPreferredMode    = TransportPreferences.keyPreferredMode

    /// Where the custom server's user name and password are kept. Only a unit test replaces it (the test bundle has no
    /// Keychain access group).
    public static var credentialStore: TransportTurnCredentialStore = KeychainTransportTurnCredentialStore()

    static var preferences: TransportPreferences {
        return TransportPreferences(credentials: credentialStore)
    }

    /// `auto` | `p2p` | `turn` | `relay`; `auto` when nothing (or something
    /// unreadable) is stored.
    public static var mode: TransportSettingsViewModel.Mode {
        return preferences.mode
    }

    /// User-supplied custom TURN server, as `turn:user:password@host:port`
    /// (`turn:` or `turns:` only; anything else, and an address without user
    /// name and password, reads as none). The address comes from UserDefaults and
    /// the user name and password from the Keychain, put together here for the
    /// call. Modes that can use it (every mode but
    /// p2p) use it as the SOLE server (no pool server, no WSS bridge); useful
    /// for self-hosted TURN deployments and for QA in restricted network
    /// environments. libwebrtc refuses a TURN server without a user name and
    /// password, so the server gets the ones the user wrote and never the
    /// temporary TURN credentials of the BCrypto server (see `TransportPlan`
    /// and `TransportCustomTurn`). The value holds a password: never log it.
    public static var preferredTurnUrl: URL? {
        return preferences.customTurnUrl
    }

    /// The mode as the string that is stored.
    public static var preferredMode: String {
        return mode.rawValue
    }

    /// `true` when the ICE transport policy of the mode is `.relay`, i.e.
    /// no direct candidates:
    ///   - auto/p2p → .all (host, srflx and relay candidates may exist)
    ///   - turn/relay → .relay (only relay candidates)
    public static var forcesRelay: Bool {
        return TransportPlan.icePolicy(for: mode) == .relay
    }

    /// What a call built now would use (the bridge answer is only known at
    /// call setup).
    public static func plan(bridgeAvailable: Bool = false) -> TransportPlan {
        return preferences.plan(bridgeAvailable: bridgeAvailable)
    }

    /// Saves the mode and the custom server (`customTurnUrl` has the credentials
    /// in it; they go to the Keychain, the address alone to UserDefaults).
    /// `false` when the Keychain refused the credentials: nothing was changed.
    @discardableResult
    public static func save(mode: TransportSettingsViewModel.Mode, customTurnUrl: URL?) -> Bool {
        return preferences.save(mode: mode, customTurnUrl: customTurnUrl)
    }
}
