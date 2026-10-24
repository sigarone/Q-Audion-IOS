import Foundation

/// Decisions of the "Share location" app intent that need no AppIntents type, so the unit tests can drive them directly
/// (the Siri / Shortcuts side of location sharing, docs/LOCATION_SHARING.md). Foundation only.
///
/// The intent never sends anything: it opens the chat of the chosen contact and presents the existing share sheet, where
/// the user confirms with a tap. This file decides which contacts the intent may list, whether it may run at all, and how
/// long a hand-off to the chat stays valid.

/// The only facts about a contact the intent reads: the account id (to open the chat) and the name Siri shows and matches.
struct LocationShareContactFacts: Equatable {
    var userId: String
    var displayName: String
}

/// What the user asked for. A live share takes one of the durations of the share sheet.
enum LocationShareRequestMode: Equatable {
    case instant
    case live(seconds: Int64)

    /// The durations of the sheet (DU_PRESETS): 15 minutes, 1 hour, 8 hours, 24 hours.
    static let livePresets: [Int64] = [900, 3_600, 28_800, 86_400]

    /// The duration the sheet highlights; `nil` for a one-off position.
    var suggestedLiveSeconds: Int64? {
        if case .live(let seconds) = self, Self.livePresets.contains(seconds) { return seconds }
        return nil
    }
}

/// A request left for the chat screen: open the share sheet of the 1:1 chat with `peerUserId`.
struct LocationShareRequest: Equatable {
    var peerUserId: String
    var mode: LocationShareRequestMode
    var createdAt: Date
}

enum LocationShareIntentGate: Equatable {
    case proceed
    case featureOff
    case signedOut
    case contactNotFound
}

enum LocationShareIntentPolicy {

    /// How long a request waits for its chat to appear (a cold launch, the lock screen of the app) before it is dropped.
    static let requestLifetime: TimeInterval = 120

    /// Whether the intent may run. A hidden feature is not reachable (the flag is checked first), then the session, then the contact.
    static func gate(featureEnabled: Bool, signedIn: Bool, contactAvailable: Bool) -> LocationShareIntentGate {
        guard featureEnabled else { return .featureOff }
        guard signedIn else { return .signedOut }
        guard contactAvailable else { return .contactNotFound }
        return .proceed
    }

    /// The contacts the intent may list: nothing while signed out or while the app is locked (the names stay behind the lock),
    /// never a blocked contact, never an empty id or name, each account once, sorted by name.
    static func listable(
        _ contacts: [LocationShareContactFacts],
        blocked: Set<String>,
        signedIn: Bool,
        appLocked: Bool
    ) -> [LocationShareContactFacts] {
        guard signedIn, !appLocked else { return [] }
        var seen: Set<String> = []
        var result: [LocationShareContactFacts] = []
        for contact in contacts {
            let id = contact.userId.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = contact.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, !name.isEmpty, !blocked.contains(id), !seen.contains(id) else { continue }
            seen.insert(id)
            result.append(LocationShareContactFacts(userId: id, displayName: name))
        }
        return result.sorted {
            let order = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
            return order == .orderedSame ? $0.userId < $1.userId : order == .orderedAscending
        }
    }

    /// The contacts whose name contains what Siri heard (case and accents ignored). An empty query matches nobody: a request
    /// with no name is not a request for the whole address book.
    static func matching(_ contacts: [LocationShareContactFacts], query: String) -> [LocationShareContactFacts] {
        let needle = fold(query)
        guard !needle.isEmpty else { return [] }
        return contacts.filter { fold($0.displayName).contains(needle) }
    }

    /// The listed contacts with these ids, in the order asked; unknown ids are left out.
    static func resolving(_ contacts: [LocationShareContactFacts], ids: [String]) -> [LocationShareContactFacts] {
        ids.compactMap { id in contacts.first(where: { $0.userId == id }) }
    }

    /// Whether a request is still worth showing. A request from the future (a clock change) is dropped as well.
    static func isFresh(_ request: LocationShareRequest, now: Date) -> Bool {
        let age = now.timeIntervalSince(request.createdAt)
        return age >= 0 && age <= requestLifetime
    }

    /// Whether `request` is meant for the chat with `peerUserId`.
    static func matches(_ request: LocationShareRequest, peerUserId: String) -> Bool {
        !peerUserId.isEmpty && request.peerUserId == peerUserId
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
