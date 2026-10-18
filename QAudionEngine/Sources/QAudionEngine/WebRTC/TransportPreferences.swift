import Foundation

/// The two values Settings > Trasporto stores for the calls: the mode and the custom TURN server. A call reads them when
/// it builds its controller, so a change made on the screen applies from the next call.
///
/// What a mode does is decided by `TransportPlan`, not here. This type only stores and reads, and always hands back a
/// usable value: an unknown stored mode reads as `auto`, a server that is not usable reads as none.
///
/// Where each piece lives:
///  - the mode, and the address of the custom server without any credential (`turn:host:port`), in `UserDefaults` under
///    the keys below (the same keys the app's `TransportGate` has always used);
///  - the user name and the password of the custom server in the Keychain (`TransportTurnCredentialStore`), under the host
///    of the address. They are never written to `UserDefaults`.
///
/// A usable server has both: the address and its own credentials (`turn:user:password@host:port` is the one-text form the
/// calls get, see `TransportCustomTurn`). An address without credentials in the Keychain reads as none for the calls, and
/// `storedAddressText` still gives it back so the screen can show it and ask for them.
///
/// Earlier builds stored the whole `turn:user:password@host:port` text in `UserDefaults`. The first read finds it, moves
/// the credentials to the Keychain and rewrites the `UserDefaults` value as the address alone; the value with the password
/// is gone from `UserDefaults` from then on. If the Keychain refuses the write the old value is left alone (nothing is
/// lost, and the calls keep reading it) and the move is tried again at the next read.
public struct TransportPreferences {

    public static let keyPreferredTurnUrl = "qaudion.transport.preferred_turn_url"
    public static let keyPreferredMode = "qaudion.transport.preferred_mode"

    private let defaults: UserDefaults
    private let credentialStore: TransportTurnCredentialStore

    public init(defaults: UserDefaults = .standard,
                credentials: TransportTurnCredentialStore = KeychainTransportTurnCredentialStore()) {
        self.defaults = defaults
        self.credentialStore = credentials
    }

    public var mode: TransportSettingsViewModel.Mode {
        let raw = defaults.string(forKey: Self.keyPreferredMode) ?? ""
        return TransportSettingsViewModel.Mode(rawValue: raw) ?? .auto
    }

    /// The custom server as the calls use it, in the one-text form with the credentials in it
    /// (`turn:user:password@host:port`), or `nil` when there is none or it is not usable: no address, an address that is
    /// not a TURN address, or no credentials in the Keychain for its host. The value holds the password: never log it.
    public var customTurnUrl: URL? {
        let stored = loadStored()
        guard !stored.addressText.isEmpty, let credentials = stored.credentials else { return nil }
        return TransportCustomTurn.make(address: stored.addressText,
                                        username: credentials.username,
                                        password: credentials.password)?.storedURL
    }

    /// The address text as it is stored, usable or not (empty when there is none), without any credential. The calls never
    /// read this: they read `customTurnUrl`.
    public var storedAddressText: String {
        loadStored().addressText
    }

    /// The credentials kept for the stored address, or `nil` when there are none. For the screen: the calls read
    /// `customTurnUrl`.
    public var storedCredentials: TransportTurnCredentials? {
        loadStored().credentials
    }

    /// What a call built now would use. `bridgeAvailable` is only known later, at call setup.
    public func plan(bridgeAvailable: Bool = false) -> TransportPlan {
        TransportPlan.make(mode: mode, customTurnUrl: customTurnUrl, bridgeAvailable: bridgeAvailable)
    }

    /// Stores the mode and the custom server. `customTurnUrl` is the one-text form with the credentials in it; its address
    /// goes to `UserDefaults` and its credentials to the Keychain. `nil`, or anything that is not a usable server, clears
    /// the saved server and its credentials.
    ///
    /// The credentials are written first. When the Keychain refuses them nothing is changed (neither the mode nor the
    /// address), so what the calls read stays what it was, and the result is `false`.
    @discardableResult
    public func save(mode: TransportSettingsViewModel.Mode, customTurnUrl: URL?) -> Bool {
        let previousHost = TransportCustomTurn.parseAddress(loadStored().addressText)?.host
        let server: TransportCustomTurn? = customTurnUrl.flatMap { TransportCustomTurn.parse($0.absoluteString).server }
        if let server = server {
            let credentials = TransportTurnCredentials(username: server.username, password: server.credential)
            guard credentialStore.save(credentials, forHost: server.host) else { return false }
            defaults.set(server.iceUrl, forKey: Self.keyPreferredTurnUrl)
        } else {
            defaults.removeObject(forKey: Self.keyPreferredTurnUrl)
        }
        // The server saved before is not the saved one any more: its credentials are not kept.
        if let previousHost = previousHost, previousHost != server?.host {
            credentialStore.remove(forHost: previousHost)
        }
        defaults.set(mode.rawValue, forKey: Self.keyPreferredMode)
        return true
    }

    // MARK: - Reading what is stored

    fileprivate struct Stored {
        let addressText: String
        let credentials: TransportTurnCredentials?
    }

    /// The stored address (never with credentials in it) and the credentials kept for it. Moves a value written by an
    /// earlier build, with the password inside, to the Keychain first.
    private func loadStored() -> Stored {
        guard let raw = defaults.string(forKey: Self.keyPreferredTurnUrl), !raw.isEmpty else {
            return Stored(addressText: "", credentials: nil)
        }
        if let legacy = TransportCustomTurn.parse(raw).server {
            let credentials = TransportTurnCredentials(username: legacy.username, password: legacy.credential)
            if credentialStore.save(credentials, forHost: legacy.host) {
                defaults.set(legacy.iceUrl, forKey: Self.keyPreferredTurnUrl)
            }
            return Stored(addressText: legacy.iceUrl, credentials: credentials)
        }
        let credentials = TransportCustomTurn.parseAddress(raw).flatMap { credentialStore.credentials(forHost: $0.host) }
        return Stored(addressText: raw, credentials: credentials)
    }
}
