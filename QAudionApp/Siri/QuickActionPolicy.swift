import Foundation

/// Decisions of the Home Screen quick actions (long press on the app icon) and of the "Nuovo messaggio" app intent that need no
/// UIKit type, so the unit tests can drive them directly. Foundation only.
///
/// The icon menu is dynamic: the app sets the items itself, so "Condividi posizione" is there only while location sharing is
/// switched on for this user and somebody is signed in, and the menu is empty after a sign-out. A static Info.plist entry cannot
/// follow the remote switch, and would be tappable when the feature is off. The system keeps dynamic items between launches, so a
/// stale item can still arrive (the flag went off while the app was not running): `take` checks again and drops it.
///
/// Nothing in here carries a name, an id or a position.

enum QuickActionKind: String, CaseIterable, Equatable {
    case shareLocation = "com.qaudion.app.quickaction.share-location"
    case newMessage = "com.qaudion.app.quickaction.new-message"
}

/// What the user asked for, left for the chat list. One-shot: taken once, dropped when stale, on a sign-out or on a wipe.
struct QuickActionRequest: Equatable {
    var kind: QuickActionKind
    /// The account that was signed in when the request was made. `nil` for a cold launch, where the session is not restored yet:
    /// such a request is accepted only if somebody is signed in when it is taken, within `requestLifetime`.
    var accountId: String?
    var createdAt: Date
}

/// What the chat list shows for a request.
enum QuickActionPresentation: Equatable {
    /// The new-conversation sheet (the same as the pencil of the list header).
    case newMessage
    /// The picker of one contact, then the chat with the share sheet of location.
    case locationPicker
}

enum QuickActionPolicy {

    /// How long a request waits for the list to appear (a cold launch, the lock screen of the app) before it is dropped.
    static let requestLifetime: TimeInterval = 120

    /// The items of the icon menu, in the order shown. Nothing while signed out.
    static func visibleKinds(signedIn: Bool, locationEnabled: Bool) -> [QuickActionKind] {
        guard signedIn else { return [] }
        return locationEnabled ? [.shareLocation, .newMessage] : [.newMessage]
    }

    /// The kind of an item the system delivers; `nil` for a type the app does not know.
    static func kind(forType type: String) -> QuickActionKind? {
        QuickActionKind(rawValue: type)
    }

    /// Whether a request is still worth showing. A request from the future (a clock change) is dropped as well.
    static func isFresh(_ request: QuickActionRequest, now: Date) -> Bool {
        let age = now.timeIntervalSince(request.createdAt)
        return age >= 0 && age <= requestLifetime
    }

    /// Takes the request out of the slot, once, and says what to show.
    ///
    /// - Behind the app lock the request waits in the slot: nothing is listed until the user unlocks (and it expires meanwhile).
    /// - A stale request, one of another account, one taken while nobody is signed in, and a location request while the feature is
    ///   off are dropped from the slot and answer `nil`.
    static func take(
        _ slot: inout QuickActionRequest?, accountId: String?, signedIn: Bool, locationEnabled: Bool, appLocked: Bool, now: Date
    ) -> QuickActionPresentation? {
        guard let request = slot else { return nil }
        guard isFresh(request, now: now), signedIn else {
            slot = nil
            return nil
        }
        if let bound = request.accountId, bound != accountId {
            slot = nil
            return nil
        }
        if appLocked { return nil }
        slot = nil
        switch request.kind {
        case .newMessage:
            return .newMessage
        case .shareLocation:
            return locationEnabled ? .locationPicker : nil
        }
    }
}

/// What a sheet of the chat list asked for (a picked contact, a chat to open), kept until the sheet is gone. Foundation only.
enum QuickActionHandoff {
    /// Takes the pick out of the slot, once, and answers it while the app is active. While it is not (the app is leaving the
    /// foreground) the pick stays in the slot, to be taken at the next `.active` scene phase.
    static func take<T>(_ slot: inout T?, appActive: Bool) -> T? {
        guard appActive, let pick = slot else { return nil }
        slot = nil
        return pick
    }

    /// How long a pick waits for the app to be active again.
    static let pickLifetime: TimeInterval = 30

    enum PickOutcome: Equatable {
        case none
        case waiting
        case expired
        case run(String)
    }

    /// Takes the contact picked in the location sheet: runs it while the app is active and the pick is young enough, keeps it
    /// (`.waiting`) while the app is not active, and drops it (`.expired`) once it is older than `pickLifetime`.
    static func takePick(_ slot: inout QuickActionPick?, appActive: Bool, now: Date) -> PickOutcome {
        guard let pick = slot else { return .none }
        let age = now.timeIntervalSince(pick.at)
        guard age >= 0, age <= pickLifetime else {
            slot = nil
            return .expired
        }
        guard appActive else { return .waiting }
        slot = nil
        return .run(pick.contactId)
    }
}

/// A contact picked in the location sheet and when.
struct QuickActionPick: Equatable {
    var contactId: String
    var at: Date
}
