import Foundation

/// Bridge between the CarPlay scene (a *separate* `UIScene` that must NEVER
/// reference `AppState` directly — see CLAUDE.md §16 "NEVER take AppState as a
/// direct parameter type in a NEW Swift file") and the live application state.
///
/// `AppState.initialize()` injects the `placeCall` closure; the CarPlay
/// templates invoke it to start an outgoing post-quantum call. This file is
/// pure Foundation — no `CarPlay` / `CallKit` / `Intents` imports and no
/// `AppState` parameter anywhere — so it ALWAYS compiles regardless of the
/// `QAUDION_CARPLAY` compilation flag and never trips the Swift-6
/// AppState-Sendable-inference trap that silently breaks the IPA build.
///
/// Design mirrors `LiveLogStreamer.shared.start(serverUrl:getToken:getUserId:)`
/// (W417): primitives + closures only.
@MainActor
public final class CarPlayBridge {

    public static let shared = CarPlayBridge()

    private init() {}

    // MARK: - Injected by AppState.initialize()

    /// Start an outgoing call to `peerUserId`. `displayName` is used only as the
    /// human-readable label on the call UI; routing keys off `peerUserId`.
    /// Wired by `AppState` so the CarPlay scene can dial without importing it.
    public var placeCall: ((_ peerUserId: String, _ displayName: String) -> Void)?

    /// Fired when a CarPlay head unit connects / disconnects. Optional — lets
    /// `AppState` (or telemetry) react to the in-car session lifecycle. nil-safe.
    public var onCarPlayConnected: (() -> Void)?
    public var onCarPlayDisconnected: (() -> Void)?

    /// W-ORPHANPEER — peers whose account no longer exists on the server, kept
    /// in sync by `AppState`. The CarPlay contacts tab is a "who can I reach"
    /// surface (its rows dial straight through `requestCall`), so it has to
    /// honour the same exclusion as the phone's address book. Plain stored
    /// property rather than a closure because the scene reads it while
    /// building rows, not in response to an event.
    public var orphanPeerIds: Set<String> = []

    // MARK: - Called by the CarPlay templates

    /// Place an outgoing call from a CarPlay row tap. No-op if the app hasn't
    /// wired `placeCall` yet (e.g. CarPlay connected before `initialize()`).
    public func requestCall(peerUserId: String, displayName: String) {
        placeCall?(peerUserId, displayName)
    }

    public func carPlayConnected() { onCarPlayConnected?() }
    public func carPlayDisconnected() { onCarPlayDisconnected?() }
}
