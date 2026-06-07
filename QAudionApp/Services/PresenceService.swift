import Foundation
import Combine
import QAudionEngine

/// W445: Extended presence states matching Android ContactRowUi.Presence.
/// Maps from raw server status strings (`BCryptoPresenceManager.Status`)
/// to typed states understood by the iOS UI layer.
///
/// The engine only exposes `.online` / `.offline` / `.unknown`.
/// `inCall` is inferred client-side from `AppState.$isInCall` /
/// `AppState.$callContactId` via `observeCallState(_:)`.
public enum ExtendedPresence: Equatable, Sendable {
    case online
    case offline
    case inCall
    case doNotDisturb
    case invisible  // appears offline but flagged in metadata
    case unknown

    /// Map from `BCryptoPresenceManager.Status` + optional raw status
    /// string. If the engine ever forwards the raw server string
    /// (e.g. "in_call"), the raw path kicks in for finer-grained
    /// states. Without raw strings the server-side nuances are inferred
    /// client-side (see `observeCallState(_:)` in `PresenceService`).
    static func from(
        status: BCryptoPresenceManager.Status,
        raw: String? = nil
    ) -> ExtendedPresence {
        switch status {
        case .online:
            guard let raw = raw else { return .online }
            if raw == "in_call" || raw == "incall" { return .inCall }
            if raw == "dnd" || raw == "do_not_disturb" { return .doNotDisturb }
            if raw == "invisible" { return .invisible }
            return .online
        case .offline:
            return .offline
        default:
            return .unknown
        }
    }

    /// Localised label shown in presence labels and detail screens.
    var label: String {
        switch self {
        case .online:        return "Online"
        case .offline:       return "Offline"
        case .inCall:        return "In chiamata"
        case .doNotDisturb:  return "Non disturbare"
        case .invisible:     return "Non visibile"
        case .unknown:       return ""
        }
    }

    /// Semantic color key used to drive presence dot color in views.
    var semanticColor: PresenceColorKey {
        switch self {
        case .online:                          return .success
        case .inCall:                          return .pqcAccent
        case .doNotDisturb:                    return .warning
        case .offline, .invisible, .unknown:   return .muted
        }
    }
}

/// Semantic color role for a presence indicator dot.
/// Views resolve this to a concrete `Color` via the design-system extras.
public enum PresenceColorKey {
    case success
    case pqcAccent
    case warning
    case muted
}

// MARK: -

/// Thin Observable wrapper around `BCryptoPresenceManager` so the
/// SwiftUI layer can render online/offline dots without poking the
/// engine directly.
///
/// Lifecycle:
///  - `attach(provider:)` is called once after auth-success — it builds
///    a single `BCryptoPresenceManager` instance bound to the live WS
///    transport and registers a `statusChanged` callback that flushes
///    into `@Published var statuses`.
///  - `subscribe(userIds:)` replaces the tracked set on the wire (the
///    server treats each `presence_subscribe` as authoritative). The
///    natural caller is the contacts list / conversations list once
///    they have loaded the visible userIds.
///  - `status(for:)` is a read-through for views that need a single dot
///    without subscribing the whole map.
///  - `extendedPresence(for:)` is the W445 extended read-through.
///  - `observeCallState(_:)` wires Combine to infer `.inCall` from
///    `AppState.$isInCall` + `AppState.$callContactId` without the engine
///    needing to expose "in_call" as a raw status string.
@MainActor
final class PresenceService: ObservableObject {

    /// Most-recently-seen status per userId, in canonical engine values
    /// (`.online` / `.offline` / `.unknown`). Never nil — missing keys
    /// default to `.unknown` via `status(for:)`.
    @Published private(set) var statuses: [String: BCryptoPresenceManager.Status] = [:]

    /// W445: Extended presence states derived from `statuses` + call-state
    /// inference. Views should prefer this over `statuses` for any UI that
    /// needs to distinguish InCall / DND / Invisible from plain Online.
    @Published private(set) var extendedStatuses: [String: ExtendedPresence] = [:]

    private var manager: BCryptoPresenceManager?
    private var subscribed: Set<String> = []

    /// Cancellables for the Combine subscription to AppState call state.
    private var callStateCancellables: Set<AnyCancellable> = []

    // MARK: - Engine binding

    /// Bind to the live engine. Idempotent — calling with the same
    /// provider replaces the manager and re-subscribes any tracked ids
    /// so the new WS connection picks up the same state.
    func attach(provider: BCryptoBackendProvider) {
        let mgr = provider.presenceManager
        // Statuses arrive on a background queue inside the engine; the
        // manager promises main-queue dispatch on `statusChanged` but
        // we still hop to MainActor to satisfy `@MainActor` isolation.
        mgr.statusChanged = { [weak self] snapshot in
            DispatchQueue.main.async {
                guard let self else { return }
                self.statuses = snapshot
                // W445: map engine statuses → extended presence.
                // Preserve any .inCall overrides set via observeCallState.
                var ext: [String: ExtendedPresence] = [:]
                for (userId, engineStatus) in snapshot {
                    // Don't overwrite a client-inferred .inCall with a
                    // stale .online from the server — the call is still
                    // active if observeCallState already set it.
                    if self.extendedStatuses[userId] == .inCall, engineStatus == .online {
                        ext[userId] = .inCall
                    } else {
                        ext[userId] = ExtendedPresence.from(status: engineStatus)
                    }
                }
                self.extendedStatuses = ext
                // W142: stamp "last seen" for every userId observed
                // online. The tracker throttles internally so a noisy
                // presence stream doesn't thrash UserDefaults.
                for (userId, status) in snapshot where status == .online {
                    LastSeenTracker.recordOnline(userId)
                }
            }
        }
        self.manager = mgr
        // Re-emit on reconnect — if we had a tracked set from a previous
        // attach, restore it on the new transport.
        if !subscribed.isEmpty {
            mgr.subscribe(userIds: Array(subscribed))
        }
    }

    // MARK: - Subscription management

    /// Replace the tracked set. Server treats this as authoritative.
    /// Drops cached statuses for users no longer tracked so the UI
    /// doesn't display stale online dots after a contact is removed.
    /// W411: when the user has disabled "Presenza visibile ai
    /// contatti" in Privacy settings, this becomes a no-op — we
    /// don't subscribe to anyone's presence (so we don't see online
    /// dots) AND we don't emit subscribe envelopes to the server.
    /// The latter is the closest a client can get to "private mode"
    /// without server-side support: contacts can still infer we're
    /// online from our WS connection state, but the app does not
    /// actively advertise us as a presence subscriber. Honest
    /// limitation: full server-side hiding requires a dedicated
    /// /api/v1/account/presence endpoint that doesn't exist yet.
    func subscribe(userIds: [String]) {
        let set = Set(userIds.filter { !$0.isEmpty })
        subscribed = set
        statuses = statuses.filter { set.contains($0.key) }
        extendedStatuses = extendedStatuses.filter { set.contains($0.key) }
        guard PrivacyGate.presenceVisibleToContacts else {
            // Off → don't subscribe; presence dots stay grey.
            return
        }
        manager?.subscribe(userIds: Array(set))
    }

    // MARK: - Read helpers

    /// Convenience helper for views that only need a single dot.
    /// Retained for backwards compatibility.
    func isOnline(_ userId: String) -> Bool {
        return (statuses[userId] ?? .unknown) == .online
    }

    func status(for userId: String) -> BCryptoPresenceManager.Status {
        return statuses[userId] ?? .unknown
    }

    /// W445: Extended presence for a single userId. Prefers the
    /// client-inferred extended state over the raw engine state.
    func extendedPresence(for userId: String) -> ExtendedPresence {
        return extendedStatuses[userId] ?? .unknown
    }

    // MARK: - Call-state inference (W445)

    /// Override a single userId's extended presence to `.inCall` (or
    /// revert to the last known engine status when the call ends).
    /// Called by `observeCallState(_:)` via Combine.
    func setInCall(userId: String, inCall: Bool) {
        if inCall {
            extendedStatuses[userId] = .inCall
        } else {
            let base = statuses[userId] ?? .unknown
            extendedStatuses[userId] = ExtendedPresence.from(status: base)
        }
    }

    /// Wire Combine to infer the peer's `.inCall` state from the provided
    /// published-property streams. Call once from a view's `.onAppear` (e.g.
    /// `ContactsListView`). Idempotent — duplicate calls replace the prior
    /// subscription rather than stacking.
    ///
    /// Caller: `appState.presenceService.observeCallState(
    ///     callContactId: appState.$callContactId.eraseToAnyPublisher(),
    ///     isInCall: appState.$isInCall.eraseToAnyPublisher())`
    func observeCallState(
        callContactId: AnyPublisher<String?, Never>,
        isInCall: AnyPublisher<Bool, Never>
    ) {
        callStateCancellables.removeAll()
        Publishers.CombineLatest(callContactId, isInCall)
            .receive(on: RunLoop.main)
            .sink { [weak self] contactId, inCall in
                guard let self else { return }
                if let uid = contactId, inCall {
                    self.setInCall(userId: uid, inCall: true)
                } else {
                    // Call ended — revert all .inCall statuses to their
                    // last known engine state.
                    for (uid, presence) in self.extendedStatuses where presence == .inCall {
                        let base = self.statuses[uid] ?? .unknown
                        self.extendedStatuses[uid] = ExtendedPresence.from(status: base)
                    }
                }
            }
            .store(in: &callStateCancellables)
    }

    // MARK: - Teardown

    /// Clear local state on logout. Also drops the manager reference so
    /// the next auth-success builds a fresh one bound to the new WS.
    func reset() {
        manager?.statusChanged = nil
        manager = nil
        subscribed.removeAll()
        statuses.removeAll()
        extendedStatuses.removeAll()
        callStateCancellables.removeAll()
    }
}
