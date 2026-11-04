import Combine
import Foundation

/// State behind the sheet where an already approved device approves or denies a new sign-in.
///
/// The server is the source of truth: every entry point (launch, foreground, the `login_approval_pending`
/// notice over the socket or as a push) calls `refresh()`, which shows what the server lists. Rules, each
/// pinned by `LoginApprovalModelTests`:
///  - an empty list shows nothing; the entry shown is the oldest one;
///  - approve and deny take the id of the entry that was displayed; an id that is no longer in the list is refused
///    (nothing sent, the list is read again), and so is a number that is not one of that entry's choices;
///  - approve sends the number the person tapped; deny sends nothing else; both are signed by the API;
///  - a wrong number is a 403 on the server, which closes the entry as denied (no retry): the entry goes
///    away and the outcome says so;
///  - 409 (already resolved by someone else) and 404/410 (gone) remove the entry with their own outcome;
///  - a network failure keeps the entry and raises `.failed`, so the person can try again;
///  - one action at a time (`isBusy` is set before the request starts);
///  - a rejected session (`BCryptoError.unauthorized`) clears the state silently; `reset()` and a lock drop
///    it, and an answer that arrives afterwards changes nothing;
///  - nothing about the request (ids, device names, numbers) is logged.
@MainActor
public final class LoginApprovalModel: ObservableObject {
    public enum Outcome: Equatable, Sendable {
        case approved
        case denied
        case wrongCode
        case alreadyResolved
        case failed
    }

    @Published public private(set) var requests: [LoginApprovalRequest] = []
    @Published public private(set) var isBusy = false
    @Published public private(set) var outcome: Outcome?

    private let api: DeviceApprovalApi
    private var epoch = 0
    private var locked = false
    private var handledIds: Set<String> = []

    public init(api: DeviceApprovalApi) {
        self.api = api
    }

    /// The entry to show: the oldest one (no date sorts last).
    public var current: LoginApprovalRequest? {
        requests.min { ($0.createdAt ?? .distantFuture) < ($1.createdAt ?? .distantFuture) }
    }

    public func refresh() async {
        guard !locked else { return }
        let startedIn = epoch
        do {
            let list = try await api.fetchPending()
            guard startedIn == epoch else { return }
            requests = list.filter { !handledIds.contains($0.id) }
        } catch BCryptoError.unauthorized {
            guard startedIn == epoch else { return }
            requests = []
        } catch {
            // Nothing on screen to retry, or the entry stays as it is: a failed read changes nothing.
        }
    }

    /// The entry `id` that was on screen when the person tapped `choice`. Never "whatever is current now": the
    /// list is read again first, and if the entry is no longer in it, or `choice` is not one of its numbers,
    /// nothing is signed or sent and the sheet shows what the server really holds.
    public func approve(id: String, choice: String) async {
        guard !isBusy else { return }
        isBusy = true
        let startedIn = epoch
        await refresh()
        guard startedIn == epoch else { return }
        guard let target = requests.first(where: { $0.id == id }), target.choices.contains(choice) else {
            isBusy = false
            return
        }
        outcome = nil
        do {
            let result = try await api.approve(id: target.id, matchCode: choice)
            guard startedIn == epoch else { return }
            switch result {
            case .done: finish(target, .approved)
            case .wrongCode: finish(target, .wrongCode)
            case .alreadyResolved, .gone: finish(target, .alreadyResolved)
            }
        } catch {
            guard startedIn == epoch else { return }
            fail(error)
        }
    }

    /// Denies the entry `id` that was on screen; same rule as `approve(id:choice:)`.
    public func deny(id: String) async {
        guard !isBusy else { return }
        isBusy = true
        let startedIn = epoch
        await refresh()
        guard startedIn == epoch else { return }
        guard let target = requests.first(where: { $0.id == id }) else {
            isBusy = false
            return
        }
        outcome = nil
        do {
            let result = try await api.deny(id: target.id)
            guard startedIn == epoch else { return }
            switch result {
            case .done: finish(target, .denied)
            case .wrongCode, .alreadyResolved, .gone: finish(target, .alreadyResolved)
            }
        } catch {
            guard startedIn == epoch else { return }
            fail(error)
        }
    }

    /// The outcome was shown.
    public func acknowledgeOutcome() {
        outcome = nil
    }

    public func setLocked(_ value: Bool) {
        locked = value
        if value { reset() }
    }

    /// Sign-out, wipe, change of account, lock.
    public func reset() {
        epoch += 1
        requests = []
        isBusy = false
        outcome = nil
        handledIds = []
    }

    private func finish(_ target: LoginApprovalRequest, _ result: Outcome) {
        handledIds.insert(target.id)
        requests.removeAll { $0.id == target.id }
        isBusy = false
        outcome = result
    }

    private func fail(_ error: Error) {
        isBusy = false
        if case BCryptoError.unauthorized = error {
            requests = []
            return
        }
        outcome = .failed
    }
}
