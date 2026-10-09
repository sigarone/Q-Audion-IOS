import Combine
import Foundation

/// State behind the holder's banner for a pending phone-number transfer. The server is the source of
/// truth: every entry point (launch, return to the foreground, the WebSocket notice) calls `refresh()`,
/// which asks the server for the list and shows what it returns. The only action is `cancel()`.
///
/// Rules, each pinned by `PhoneTransferNoticeModelTests`:
///  - an empty list shows nothing;
///  - the device clock never removes an entry: whatever the server lists is shown, so a clock that runs
///    ahead cannot hide a live transfer from its holder;
///  - requests do not overlap: a refresh asked while another one runs shares it, and a refresh that must
///    not be missed (`throttled == false`) makes the running one repeat once when it ends;
///  - `throttled` refreshes (foreground, reconnect) are skipped within `minRefreshInterval` of the last
///    request; launch, the WebSocket notice, retry and the read after a cancel are never throttled;
///  - a 404 on the list or on a cancel hides the entry, with no message;
///  - any other failure keeps the entry and raises a neutral `problem`, so the action can be retried;
///    a failed list refresh with nothing on screen stays silent, since there is nothing to retry;
///  - a rejected session (`BCryptoError.unauthorized`) clears the state silently;
///  - a cancelled entry never comes back, even if a list request started before the cancel answers later;
///  - no error text, URL or transfer id is logged or kept: `problem` is a plain case.
@MainActor
public final class PhoneTransferNoticeModel: ObservableObject {
    public enum Problem: Equatable, Sendable {
        case refreshFailed
        case cancelFailed
    }

    @Published public private(set) var transfers: [PhoneTransferPending] = []
    @Published public private(set) var problem: Problem?
    @Published public private(set) var isCancelling = false

    private let api: PhoneTransferApi
    private let minRefreshInterval: TimeInterval
    private let now: @Sendable () -> Date
    private var refreshGeneration = 0
    private var cancelledIds: Set<String> = []
    private var inFlight: Task<Void, Never>?
    private var rerunRequested = false
    private var lastStartedAt: Date?

    public init(
        api: PhoneTransferApi,
        minRefreshInterval: TimeInterval = 30,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.api = api
        self.minRefreshInterval = minRefreshInterval
        self.now = now
    }

    /// The entry to show: the one that expires first.
    public var current: PhoneTransferPending? {
        transfers.min { $0.expiresAt < $1.expiresAt }
    }

    /// Asks the server for the pending transfers and shows the result.
    public func refresh(throttled: Bool = false) async {
        if let running = inFlight {
            if !throttled { rerunRequested = true }
            await running.value
            return
        }
        if throttled, let last = lastStartedAt {
            let elapsed = now().timeIntervalSince(last)
            if elapsed >= 0 && elapsed < minRefreshInterval { return }
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runRefreshes()
        }
        inFlight = task
        await task.value
    }

    /// Cancels the entry on screen. On success (or a 404) the entry is hidden and the list is read
    /// again; on any other failure the entry stays and `problem` is `.cancelFailed`.
    public func cancel() async {
        guard !isCancelling, let target = current else { return }
        isCancelling = true
        problem = nil
        let outcome = await cancelOnServer(id: target.id)
        isCancelling = false
        switch outcome {
        case .gone:
            forget(id: target.id)
            await refresh()
        case .failed:
            problem = .cancelFailed
        case .signedOut:
            reset()
        }
    }

    /// Drops everything: sign-out, wipe, app lock, expired session, change of account.
    public func reset() {
        refreshGeneration += 1
        transfers = []
        problem = nil
        cancelledIds = []
        rerunRequested = false
        lastStartedAt = nil
    }

    private func runRefreshes() async {
        repeat {
            rerunRequested = false
            lastStartedAt = now()
            await loadOnce()
        } while rerunRequested
        inFlight = nil
    }

    private func loadOnce() async {
        refreshGeneration += 1
        let generation = refreshGeneration
        do {
            let list = try await api.fetchPending()
            guard generation == refreshGeneration else { return }
            transfers = list.filter { !cancelledIds.contains($0.id) }
            if problem == .refreshFailed { problem = nil }
        } catch {
            guard generation == refreshGeneration else { return }
            if Self.isNotFound(error) {
                transfers = []
                if problem == .refreshFailed { problem = nil }
            } else if Self.isSignedOut(error) {
                reset()
            } else if !transfers.isEmpty {
                problem = .refreshFailed
            }
        }
    }

    private enum CancelOutcome {
        case gone
        case failed
        case signedOut
    }

    private func cancelOnServer(id: String) async -> CancelOutcome {
        do {
            try await api.cancel(id: id)
            return .gone
        } catch {
            if Self.isNotFound(error) { return .gone }
            if Self.isSignedOut(error) { return .signedOut }
            return .failed
        }
    }

    /// Hides `id` for good and invalidates any list request still in flight.
    private func forget(id: String) {
        refreshGeneration += 1
        cancelledIds.insert(id)
        transfers.removeAll { $0.id == id }
    }

    private static func isNotFound(_ error: Error) -> Bool {
        guard let rest = error as? BCryptoError else { return false }
        switch rest {
        case .notFound: return true
        case .httpError(let status): return status == 404
        default: return false
        }
    }

    private static func isSignedOut(_ error: Error) -> Bool {
        guard let rest = error as? BCryptoError else { return false }
        if case .unauthorized = rest { return true }
        return false
    }
}
