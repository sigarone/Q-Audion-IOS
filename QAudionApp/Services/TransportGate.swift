import Foundation

/// W411 — single source of truth for transport-layer policy gates.
///
/// Before W411, TransportSettingsScreen persisted Mode + preferredTurn
/// values in SettingsStore that no production code path consumed. The
/// WebRTC bridge always fetched the default relay pool and used the
/// stock RTCConfiguration with `iceTransportPolicy = .all`.
///
/// W411 publishes these two values via UserDefaults so the WebRTC
/// controller can read them at peer-connection creation time.
public enum TransportGate {

    public static let keyPreferredTurnUrl = "qaudion.transport.preferred_turn_url"
    public static let keyPreferredMode    = "qaudion.transport.preferred_mode"

    /// User-supplied custom TURN URL. When set, the WebRTC bridge
    /// uses it as the SOLE relay (no server-side pool fetch); useful
    /// for self-hosted TURN deployments and for QA in restricted
    /// network environments.
    public static var preferredTurnUrl: URL? {
        guard let raw = UserDefaults.standard.string(forKey: keyPreferredTurnUrl),
              !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    /// `auto` | `p2p` | `turn` | `relay`. Maps to WebRTC's
    /// `RTCIceTransportPolicy`:
    ///   - auto/p2p → .all (any candidate, prefer host)
    ///   - turn/relay → .relay (force traffic through relay only —
    ///                  needed in carrier-NAT environments)
    public static var preferredMode: String {
        return UserDefaults.standard.string(forKey: keyPreferredMode) ?? "auto"
    }

    public static var forcesRelay: Bool {
        let m = preferredMode
        return m == "turn" || m == "relay"
    }

    public static func setPreferredTurnUrl(_ value: URL?) {
        UserDefaults.standard.set(value?.absoluteString, forKey: keyPreferredTurnUrl)
    }

    public static func setPreferredMode(_ value: String) {
        UserDefaults.standard.set(value, forKey: keyPreferredMode)
    }
}
