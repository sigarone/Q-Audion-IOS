import Foundation

/// Bridge between the CarPlay scene (a *separate* `UIScene` that must NEVER
/// reference `AppState` directly — see CLAUDE.md §16 "NEVER take AppState as a
/// direct parameter type in a NEW Swift file") and the live application state.
///
/// `AppState.initialize()` injects the closures below; the CarPlay templates
/// call them to start an outgoing post-quantum call and to read the session and
/// the app lock. This file is pure Foundation — no `CarPlay` / `CallKit` /
/// `Intents` imports and no `AppState` parameter anywhere — so it ALWAYS
/// stays free of the CarPlay framework and never
/// trips the Swift-6 AppState-Sendable-inference trap that silently breaks the
/// IPA build.
///
/// Design mirrors `LiveLogStreamer.shared.start(serverUrl:getToken:getUserId:)`
/// (W417): primitives + closures only.
///
/// COLD LAUNCH WITH ONLY THE CARPLAY SCENE. When the car starts the app and the
/// phone has no window, the SwiftUI `WindowGroup` never appears, so its
/// `onAppear` (which runs `AppState.initialize()`) never runs and `placeCall`
/// would stay nil. `bootApp` is wired by `AppDelegate` at process launch (before
/// any scene exists); the CarPlay scene calls `ensureBooted()` when it connects
/// and before it hands anything to the app, and `AppState` makes sure
/// `initialize()` runs once however the app was reached (`AppInitializeGate`).
/// The session is restored after that, so the scene lists nothing until
/// `sessionState` says `.signedIn`, and it reloads on `onSignInChanged`.
@MainActor
public final class CarPlayBridge {

    public static let shared = CarPlayBridge()

    private init() {}

    /// `NSUserActivity.activityType` SiriKit uses to continue a call request in the app. It is the literal Intents
    /// class name, the same string `Info.plist` lists under `NSUserActivityTypes`.
    public static let startCallActivityType = "INStartCallIntent"

    // MARK: - Injected before any scene exists (AppDelegate)

    /// Runs the app's one-time start-up if no phone scene did it yet. Wired by `AppDelegate` at process launch.
    public var bootApp: (@MainActor () -> Void)?

    /// Continues a Siri call request (the `NSUserActivity` of an `INStartCallIntent`) in the app. Wired by `AppDelegate`.
    public var continueStartCall: (@MainActor (NSUserActivity) -> Void)?

    // MARK: - Injected by AppState.initialize()

    /// Start an outgoing call to `peerUserId`. `displayName` is used only as the
    /// human-readable label on the call UI; routing keys off `peerUserId`.
    /// Wired by `AppState` so the CarPlay scene can dial without importing it.
    public var placeCall: ((_ peerUserId: String, _ displayName: String) -> Void)?

    /// Whether an account is signed in, not signed in, or not known yet (a stored session is being checked). nil
    /// until `AppState` has wired it, which reads as "not known yet".
    public var sessionState: (@MainActor () -> CarPlaySession)?

    /// Whether the app lock is up. nil until `AppState` has wired it, which reads as locked.
    public var isAppLocked: (@MainActor () -> Bool)?

    /// Brings the app lock up to date without asking anyone: the grace period may have run out while the phone
    /// window sat in the background. Run before every read of the lock. nil until `AppState` has wired it.
    public var refreshAppLock: (@MainActor () -> Void)?

    /// Fired when a CarPlay head unit connects / disconnects. Optional — lets
    /// `AppState` (or telemetry) react to the in-car session lifecycle. nil-safe.
    public var onCarPlayConnected: (@MainActor () -> Void)?
    public var onCarPlayDisconnected: (@MainActor () -> Void)?

    /// W-ORPHANPEER — peers whose account no longer exists on the server, kept
    /// in sync by `AppState`. The CarPlay contacts tab is a "who can I reach"
    /// surface (its rows dial straight through `requestCall`), so it has to
    /// honour the same exclusion as the phone's address book. Plain stored
    /// property rather than a closure because the scene reads it while
    /// building rows, not in response to an event.
    public var orphanPeerIds: Set<String> = []

    // MARK: - Installed by the CarPlay scene

    /// Shows a short notice on the car screen. Set while a CarPlay session is connected, nil otherwise.
    public var noticeSink: (@MainActor (CarPlayNotice) -> Void)?

    /// The scene redraws its lists. Set while a CarPlay session is connected, nil otherwise.
    public var onSignInChanged: (@MainActor () -> Void)?
    public var onLockChanged: (@MainActor () -> Void)?

    /// True between `carPlayConnected()` and `carPlayDisconnected()`.
    public private(set) var isConnected: Bool = false

    // MARK: - Reading the app

    public func currentSession() -> CarPlaySession { sessionState?() ?? .unknown }

    public func appIsLocked() -> Bool {
        refreshAppLock?()
        return isAppLocked?() ?? true
    }

    /// `AppState` calls this when the signed-in state changes.
    public func signInDidChange() { onSignInChanged?() }

    /// The phone window calls this when the app lock goes up or comes down.
    public func lockDidChange() { onLockChanged?() }

    // MARK: - Called by the CarPlay templates

    public enum CallRequestOutcome: Equatable {
        /// The request reached the app.
        case handedOver
        /// The app could not be started, so nothing was done.
        case appNotReady
        /// The app lock is up, so nothing was done.
        case locked
    }

    /// Starts the app's one-time start-up when nothing did it yet. Safe to call as often as needed.
    public func ensureBooted() {
        if placeCall == nil { bootApp?() }
    }

    /// Place an outgoing call from a CarPlay row tap. A launch with no phone scene has not wired `placeCall` yet, so
    /// the app is started first; if that does not produce a `placeCall` the answer is `.appNotReady` and the scene
    /// tells the driver, instead of the tap doing nothing. While the app lock is up nothing is dialled.
    @discardableResult
    public func requestCall(peerUserId: String, displayName: String) -> CallRequestOutcome {
        ensureBooted()
        guard let placeCall else { return .appNotReady }
        guard !appIsLocked() else { return .locked }
        placeCall(peerUserId, displayName)
        return .handedOver
    }

    /// A Siri call request that reached the CarPlay scene (the scene's `continue` callback, or the activities it was
    /// launched with). The app is started first, because on a launch with no phone scene nothing else has done it.
    /// While the app lock is up the request is not continued and the car screen says so.
    @discardableResult
    public func deliverSiriActivity(_ activity: NSUserActivity) -> Bool {
        guard activity.activityType == Self.startCallActivityType else { return false }
        ensureBooted()
        guard let continueStartCall else {
            report(.notReady)
            return false
        }
        guard !appIsLocked() else {
            report(.appLocked)
            return false
        }
        continueStartCall(activity)
        return true
    }

    /// Reports something to the driver on the car screen. Does nothing when no CarPlay session is connected.
    public func report(_ notice: CarPlayNotice) {
        noticeSink?(notice)
    }

    public func carPlayConnected() {
        isConnected = true
        ensureBooted()
        refreshAppLock?()
        onCarPlayConnected?()
    }

    public func carPlayDisconnected() {
        isConnected = false
        noticeSink = nil
        onSignInChanged = nil
        onLockChanged = nil
        onCarPlayDisconnected?()
    }
}
