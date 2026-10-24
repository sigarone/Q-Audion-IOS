import Foundation
import UIKit

/// Where the "Share location" app intent meets the app: which contacts it may list, whether it may run, and the hand-off to the
/// chat. The sheet of the chat is the confirmation; nothing is sent from here.
///
/// Primitive values and closures only, replaced by the tests. Nothing here logs a name, an id or a position: the only event is the
/// outcome and the kind of mode.
@MainActor
enum LocationShareIntentRouter {

    enum Outcome: Equatable {
        case handedOff
        case featureOff
        case signedOut
        case contactNotFound
    }

    // MARK: Seams

    static var featureEnabled: @MainActor () -> Bool = { LocationShareCenter.isFeatureEnabled }
    static var signedIn: @MainActor () -> Bool = { AppState.shared.isAuthenticated }
    /// Whether the names stay behind the lock of the app. A cold start is asked to lock first (as the car screen does), and a
    /// background time with the grace period gone counts as locked even before the lock engages.
    static var appLocked: @MainActor () -> Bool = {
        let lock = AppLockService.shared
        lock.lockIfGraceExpiredWithoutPrompt()
        let defaults = UserDefaults.standard
        let at: Date? = defaults.object(forKey: AppLockService.backgroundedAtKey) == nil
            ? nil : Date(timeIntervalSince1970: defaults.double(forKey: AppLockService.backgroundedAtKey))
        return LocationShareIntentPolicy.namesAreLocked(
            lockEnabled: PrivacyGate.appLockEnabled, isLocked: lock.isLocked,
            appActive: UIApplication.shared.applicationState == .active, backgroundedAt: at,
            graceSeconds: Double(PrivacyGate.appLockTimeoutMs) / 1000.0, now: Date())
    }
    static var accountId: @MainActor () -> String? = { AppState.shared.currentUserId }
    static var updateShortcutParameters: @MainActor () -> Void = { QAudionAppShortcuts.updateAppShortcutParameters() }
    static var allContacts: @MainActor () -> [LocationShareContactFacts] = {
        AppState.shared.reachableContacts.map { LocationShareContactFacts(userId: $0.userId, displayName: $0.displayName) }
    }
    static var blockedIds: @MainActor () -> Set<String> = { BlockedContactsStore.loadBlockedIds() }
    static var now: @MainActor () -> Date = { Date() }
    static var deliver: @MainActor (LocationShareRequest) -> Void = { request in
        AppState.shared.requestLocationShare(request)
    }

    // MARK: Contacts

    /// The contacts the intent lists to Siri and Shortcuts.
    static func listableContacts() -> [LocationShareContactFacts] {
        LocationShareIntentPolicy.listable(
            allContacts(), blocked: blockedIds(), signedIn: signedIn(), appLocked: appLocked())
    }

    /// The contacts of an id Siri or Shortcuts already holds (a saved shortcut, a disambiguation in progress). Behind the lock this
    /// lists nothing new: the caller had the id already.
    static func resolvableContacts() -> [LocationShareContactFacts] {
        LocationShareIntentPolicy.listable(
            allContacts(), blocked: blockedIds(), signedIn: signedIn(), appLocked: false)
    }

    // MARK: Parameters known to Siri

    private static var observersInstalled = false

    /// Tells Siri and Shortcuts that the list of contacts may have changed (a contact added, a block, a sign-in or sign-out), so
    /// the names they hold follow it; an empty list clears them.
    static func shortcutParametersChanged() {
        updateShortcutParameters()
    }

    /// Watches the block list. Idempotent.
    static func installObservers() {
        guard !observersInstalled else { return }
        observersInstalled = true
        NotificationCenter.default.addObserver(forName: .blockedContactsDidChange, object: nil, queue: .main) { _ in
            Task { @MainActor in shortcutParametersChanged() }
        }
    }

    // MARK: Run

    /// Runs the intent for the contact with this account id. The contact is looked up again here, with the same filters as the
    /// listing, so an id that is no longer listed (blocked, signed out meanwhile) is refused.
    static func handle(contactId: String, mode: LocationShareRequestMode) -> Outcome {
        let enabled = featureEnabled()
        let isSignedIn = signedIn()
        // The lock hides the names, not the hand-off: the request waits behind the lock screen of the app.
        let reachable = resolvableContacts()
        let available = reachable.contains(where: { $0.userId == contactId })
        switch LocationShareIntentPolicy.gate(featureEnabled: enabled, signedIn: isSignedIn, contactAvailable: available) {
        case .featureOff:
            RTLog.info("chat", "loc intent outcome=feature_off")
            return .featureOff
        case .signedOut:
            RTLog.info("chat", "loc intent outcome=signed_out")
            return .signedOut
        case .contactNotFound:
            RTLog.info("chat", "loc intent outcome=contact_not_found")
            return .contactNotFound
        case .proceed:
            let kind: String = mode == .instant ? "instant" : "live"
            RTLog.info("chat", "loc intent outcome=handed_off mode=\(kind)")
            deliver(LocationShareRequest(accountId: accountId() ?? "", peerUserId: contactId, mode: mode, createdAt: now()))
            return .handedOff
        }
    }
}

/// The sentences the intent says. None carries a name, an id or a position.
enum LocationShareIntentStrings {

    static var confirmInApp: String {
        String(localized: "location.intent.confirm", defaultValue: "Conferma in Q-Audion con un tocco per condividere la posizione.", comment: "Said by Siri after the Share location shortcut opened the app: nothing is sent until the user taps.")
    }

    static var featureOff: String {
        String(localized: "location.intent.feature_off", defaultValue: "La condivisione della posizione non è disponibile al momento.", comment: "Said by Siri when the Share location shortcut runs while the feature is switched off.")
    }

    static var signedOut: String {
        String(localized: "location.intent.signed_out", defaultValue: "Accedi a Q-Audion per condividere la posizione.", comment: "Said by Siri when the Share location shortcut runs while nobody is signed in.")
    }

    static var contactNotFound: String {
        String(localized: "location.intent.contact_not_found", defaultValue: "Non trovo questo contatto in Q-Audion.", comment: "Said by Siri when the contact of the Share location shortcut is not available.")
    }

    static func dialog(for outcome: LocationShareIntentRouter.Outcome) -> String {
        switch outcome {
        case .handedOff: return confirmInApp
        case .featureOff: return featureOff
        case .signedOut: return signedOut
        case .contactNotFound: return contactNotFound
        }
    }
}
