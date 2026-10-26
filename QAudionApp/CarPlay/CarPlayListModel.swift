import Foundation
import QAudionEngine

// What the CarPlay lists show, decided without a single CarPlay type, so the unit tests can run it on a simulator or a Mac.
// `CarPlayScene.swift` turns these values into templates.

// MARK: - Notices

/// Something the driver is told on the car screen. Every one of them is complete in itself: none of them points at
/// the phone, because a CarPlay flow has to work without touching it.
public enum CarPlayNotice: Equatable, CaseIterable {
    /// A spoken or tapped name matched nobody the app can call.
    case contactNotFound
    /// A call could not be started.
    case callNotStarted
    /// Q-Audion is not ready to place the request yet.
    case notReady
    /// The app lock is on, so no call is placed.
    case appLocked
}

// MARK: - Access

/// Whether the app has an account to list. `unknown` is the start of a launch made by the car: a stored session is
/// still being checked, which is not the same as nobody being signed in.
public enum CarPlaySession: Equatable {
    case unknown
    case signedIn
    case signedOut

    /// `hasStoredSession`: a session token is stored on the device.
    static func of(isAuthenticated: Bool, hasStoredSession: Bool) -> CarPlaySession {
        if isAuthenticated { return .signedIn }
        return hasStoredSession ? .unknown : .signedOut
    }
}

/// What the car screen may show right now.
enum CarPlayAccess: Equatable {
    case open
    /// The session is not known yet.
    case starting
    case signedOut
    /// The app lock is up: nothing is listed and nothing is dialled.
    case locked
}

// MARK: - Tabs and empty states

enum CarPlayTab: Equatable, CaseIterable {
    case recents
    case contacts
    case messages
}

/// Why a tab shows no rows.
enum CarPlayEmptyKind: Equatable {
    /// The session is not known yet.
    case starting
    /// Nobody is signed in, so nothing is listed.
    case signedOut
    /// The app lock is up, so nothing is listed.
    case locked
    /// Signed in, and there is nothing in this tab yet.
    case nothingYet(CarPlayTab)
}

// MARK: - Limits

/// How many rows a list may show. The template reports its own maximum
/// (`CPListTemplate.maximumItemCount`, across all sections), and a vehicle that limits lists
/// (`CPLimitableUserInterface.lists`) shows 12 rows whatever the template allows.
struct CarPlayListLimits: Equatable {

    /// Rows a vehicle that limits lists shows.
    static let limitedListItemCount: Int = 12

    /// The most rows the app wants on each tab when nothing limits it.
    static let wantedRecents: Int = 20
    static let wantedContacts: Int = 50
    static let wantedConversations: Int = 20

    /// `CPListTemplate.maximumItemCount`.
    var templateMaximumItems: Int
    /// `CPSessionConfiguration.limitedUserInterfaces` contains `.lists`.
    var listsLimited: Bool

    /// What to assume before CarPlay has said anything: the strictest case.
    static let conservative = CarPlayListLimits(
        templateMaximumItems: CarPlayListLimits.limitedListItemCount, listsLimited: true)

    /// The number of rows to build when the app would like `wanted`. Never negative.
    func cap(wanted: Int) -> Int {
        var rows = min(max(0, wanted), max(0, templateMaximumItems))
        if listsLimited { rows = min(rows, Self.limitedListItemCount) }
        return rows
    }
}

// MARK: - Rows

struct CarPlayRecentRow: Equatable {
    let peerUserId: String
    /// The name on the row, and the label handed to the call.
    let title: String
    let direction: CallRecord.Direction
    let durationSeconds: Int?
    let isVideo: Bool
}

struct CarPlayContactRow: Equatable {
    let userId: String
    let title: String
    let isVerified: Bool
    let phoneNumber: String?
}

struct CarPlayConversationRow: Equatable {
    /// The peer's user id: it comes back to the Siri handlers as `conversationIdentifier`.
    let conversationIdentifier: String
    let title: String
    let unreadCount: Int
    let isPinned: Bool
}

// MARK: - Builder

enum CarPlayListBuilder {

    /// The name to show for a peer: the stored name unless it is empty or only a user id, else what the app resolves
    /// the user id to.
    static func title(userId: String, storedName: String, resolve: (String) -> String) -> String {
        let name = storedName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || DisplayName.looksLikeUUID(name) { return resolve(userId) }
        return name
    }

    static func recents(
        _ records: [CallRecord],
        limits: CarPlayListLimits,
        resolve: (String) -> String
    ) -> [CarPlayRecentRow] {
        records.prefix(limits.cap(wanted: CarPlayListLimits.wantedRecents)).map { rec in
            CarPlayRecentRow(
                peerUserId: rec.peerUserId,
                title: title(userId: rec.peerUserId, storedName: rec.peerDisplayName, resolve: resolve),
                direction: rec.direction,
                durationSeconds: rec.durationSeconds,
                isVideo: rec.isVideo)
        }
    }

    /// Verified contacts first, then by name. Accounts that no longer exist on the server are left out: these rows
    /// dial on a tap (W-ORPHANPEER).
    static func contacts(
        _ contacts: [ContactsStore.StoredContact],
        orphanPeerIds: Set<String>,
        limits: CarPlayListLimits,
        resolve: (String) -> String
    ) -> [CarPlayContactRow] {
        let rows: [CarPlayContactRow] = contacts
            .filter { !shouldHideContact(orphanPeerIds.contains($0.userId)) }
            .map { c in
                // W-EXTPREFIX: a stale "Phone #100" / "New User" name goes through the canonical resolver.
                CarPlayContactRow(
                    userId: c.userId, title: resolve(c.userId), isVerified: c.isVerified, phoneNumber: c.phoneNumber)
            }
            .sorted { lhs, rhs in
                if lhs.isVerified != rhs.isVerified { return lhs.isVerified }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
        return Array(rows.prefix(limits.cap(wanted: CarPlayListLimits.wantedContacts)))
    }

    /// One-to-one conversations only: the Siri intents key off a single peer.
    static func conversations(
        _ conversations: [Conversation],
        limits: CarPlayListLimits,
        resolve: (String) -> String
    ) -> [CarPlayConversationRow] {
        conversations
            .filter { $0.kind == .oneToOne }
            .prefix(limits.cap(wanted: CarPlayListLimits.wantedConversations))
            .map { conv in
                CarPlayConversationRow(
                    conversationIdentifier: conv.peerUserId,
                    title: title(userId: conv.peerUserId, storedName: conv.peerDisplayName, resolve: resolve),
                    unreadCount: max(0, conv.unreadCount),
                    isPinned: conv.pinned)
            }
    }

    /// The pinned one-to-one conversations for the header grid of the conversations list, at most `maximum` of them.
    static func pinnedConversations(
        _ conversations: [Conversation],
        maximum: Int,
        resolve: (String) -> String
    ) -> [CarPlayConversationRow] {
        conversations
            .filter { $0.kind == .oneToOne && $0.pinned }
            .prefix(max(0, maximum))
            .map { conv in
                CarPlayConversationRow(
                    conversationIdentifier: conv.peerUserId,
                    title: title(userId: conv.peerUserId, storedName: conv.peerDisplayName, resolve: resolve),
                    unreadCount: max(0, conv.unreadCount),
                    isPinned: true)
            }
    }

    /// What may be shown for a session and a lock. A locked app shows nothing, whatever the session is.
    static func access(session: CarPlaySession, isLocked: Bool) -> CarPlayAccess {
        if isLocked { return .locked }
        switch session {
        case .signedIn: return .open
        case .unknown: return .starting
        case .signedOut: return .signedOut
        }
    }

    /// Why a tab with no rows is empty. Anything but an open app lists nothing at all.
    static func emptyKind(for tab: CarPlayTab, access: CarPlayAccess) -> CarPlayEmptyKind {
        switch access {
        case .open: return .nothingYet(tab)
        case .starting: return .starting
        case .signedOut: return .signedOut
        case .locked: return .locked
        }
    }

    /// `m:ss`, or `h:mm:ss` from an hour on.
    static func formatDuration(_ seconds: Int) -> String {
        let total = max(0, seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }
}

// MARK: - Start-up

/// Makes `AppState.initialize()` run once when the app can be reached by two doors: the phone window and the CarPlay
/// scene. Nothing here knows about `AppState`.
///
/// - The CarPlay scene asks first (a launch with only the car): it runs, and the first appearance of the phone window
///   after it does not run it again.
/// - The phone window asks first (the usual launch): it runs, and a later CarPlay connection finds it done.
/// - A phone window that appears again (a reconnected scene) runs it again, as it always has.
struct AppInitializeGate: Equatable {

    private(set) var runs: Int = 0
    private var startedByCarPlay: Bool = false

    /// True when the CarPlay scene has to run `initialize()` itself.
    mutating func carPlayNeedsInitialize() -> Bool {
        guard runs == 0 else { return false }
        runs = 1
        startedByCarPlay = true
        return true
    }

    /// True when the phone window has to run `initialize()`.
    mutating func phoneWindowNeedsInitialize() -> Bool {
        if runs == 0 {
            runs = 1
            return true
        }
        if startedByCarPlay {
            startedByCarPlay = false
            return false
        }
        runs += 1
        return true
    }
}
