import Foundation

/// Drives Settings → Transport screen.
///
/// Exposes connection-mode selection (auto / p2p / turn / relay), Tor toggle,
/// optional preferred TURN server URL, and last-measured round-trip times for
/// the general connection and the TURN relay.  The mock disables Tor and uses
/// `mode: .auto` to reflect the safe default for most users.
public struct TransportSettingsViewModel: ViewModelProtocol {

    /// Connection routing mode.
    public enum Mode: String, Sendable, CaseIterable {
        case auto, p2p, turn, relay
    }

    public let mode: Mode
    public let torEnabled: Bool
    public let preferredTurnServerUrl: URL?
    public let lastConnectionMs: Int
    public let lastTurnRoundTripMs: Int

    public init(mode: Mode, torEnabled: Bool, preferredTurnServerUrl: URL?,
                lastConnectionMs: Int, lastTurnRoundTripMs: Int) {
        self.mode = mode
        self.torEnabled = torEnabled
        self.preferredTurnServerUrl = preferredTurnServerUrl
        self.lastConnectionMs = lastConnectionMs
        self.lastTurnRoundTripMs = lastTurnRoundTripMs
    }

    public static let mock = TransportSettingsViewModel(
        mode: .auto,
        torEnabled: false,
        preferredTurnServerUrl: nil,
        lastConnectionMs: 142,
        lastTurnRoundTripMs: 38
    )
}
