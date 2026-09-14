import Foundation
import QAudionEngine

/// B9 (W-WSBANNER, 2026-09-02): pure `ConnectionState` → banner mapping for
/// the non-invasive WS-health banner surfaced in `ChatListScreen` (and any
/// future consumer). Split out of the view so the mapping is testable
/// without SwiftUI — `ChatListScreen` only adds the theme-provided tint
/// color, which needs the environment and has no decision logic of its own.
///
/// `.connected` is the brief pre-auth handshake step on the way to
/// `.authenticated` (see the "Connecting → Online" comment at
/// `AppState`'s WS state-listener) and — like `.authenticated` — maps to
/// `nil` so the banner doesn't flash on every normal login/reconnect tick.
enum ConnectionStatusBannerPolicy: Equatable {
    case disconnected
    case reconnecting

    var title: String {
        switch self {
        case .disconnected: return "Connessione al server persa"
        case .reconnecting: return "Riconnessione in corso…"
        }
    }

    var systemImage: String {
        switch self {
        case .disconnected: return "wifi.slash"
        case .reconnecting: return "arrow.triangle.2.circlepath"
        }
    }

    static func select(_ state: ConnectionState) -> ConnectionStatusBannerPolicy? {
        switch state {
        case .disconnected: return .disconnected
        case .connecting:   return .reconnecting
        case .connected, .authenticated: return nil
        }
    }
}
