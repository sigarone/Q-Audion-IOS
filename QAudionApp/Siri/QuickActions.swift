import Foundation
import UIKit

/// The Home Screen quick actions (long press on the icon): the items shown, and the hand-off of a tapped item to the chat list.
///
/// The items are set by the app (`refresh`), on the launch, on every sign-in and sign-out (`AppState.isAuthenticated`) and when the
/// remote flags are fetched, so "Condividi posizione" follows the remote switch. A tapped item is only recorded here
/// (`AppState.pendingQuickAction`); `QuickActionPolicy.take` decides in the chat list whether it is shown (session, app lock, switch).
///
/// Primitive values and closures only, replaced by the tests. Nothing here logs a name, an id or a position.
@MainActor
enum QuickActions {

    // MARK: Seams

    static var signedIn: @MainActor () -> Bool = { AppState.shared.isAuthenticated }
    static var locationEnabled: @MainActor () -> Bool = { LocationShareCenter.isFeatureEnabled }
    static var accountId: @MainActor () -> String? = { AppState.shared.currentUserId }
    static var now: @MainActor () -> Date = { Date() }
    static var setItems: @MainActor ([UIApplicationShortcutItem]) -> Void = { items in
        UIApplication.shared.shortcutItems = items
    }
    static var deliver: @MainActor (QuickActionRequest) -> Void = { request in
        AppState.shared.pendingQuickAction = request
    }

    // MARK: Items

    static func title(for kind: QuickActionKind) -> String {
        switch kind {
        case .shareLocation:
            return String(localized: "Condividi posizione")
        case .newMessage:
            return String(localized: "Nuovo messaggio")
        }
    }

    static func symbolName(for kind: QuickActionKind) -> String {
        switch kind {
        case .shareLocation: return "location.fill"
        case .newMessage: return "square.and.pencil"
        }
    }

    static func items() -> [UIApplicationShortcutItem] {
        QuickActionPolicy.visibleKinds(signedIn: signedIn(), locationEnabled: locationEnabled()).map { kind in
            UIApplicationShortcutItem(
                type: kind.rawValue,
                localizedTitle: title(for: kind),
                localizedSubtitle: nil,
                icon: UIApplicationShortcutIcon(systemImageName: symbolName(for: kind)),
                userInfo: nil)
        }
    }

    /// Sets the menu of the icon to what is allowed now.
    static func refresh() {
        setItems(items())
    }

    private static var observersInstalled = false

    /// Refreshes the menu when the remote flags are fetched. Idempotent.
    static func installObservers() {
        guard !observersInstalled else { return }
        observersInstalled = true
        NotificationCenter.default.addObserver(forName: FeatureFlags.didRefreshNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in refresh() }
        }
    }

    // MARK: Tap

    /// Records the tapped item. `false` for a type the app does not know. The session, the lock and the switch are checked when the
    /// list takes the request, because a cold launch has no restored session yet.
    @discardableResult
    static func handle(type: String) -> Bool {
        guard let kind = QuickActionPolicy.kind(forType: type) else { return false }
        let label: String = kind == .shareLocation ? "location" : "message"
        RTLog.info("chat", "quick action kind=\(label)")
        deliver(QuickActionRequest(kind: kind, accountId: signedIn() ? accountId() : nil, createdAt: now()))
        return true
    }
}

/// The scene delegate that receives an item tapped while the app is running or suspended. A tap that launches the app is in the
/// connection options, read by `AppDelegate`.
final class QuickActionSceneDelegate: UIResponder, UIWindowSceneDelegate {
    func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        let type: String = shortcutItem.type
        completionHandler(MainActor.assumeIsolated { QuickActions.handle(type: type) })
    }
}
