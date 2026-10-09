import Combine
import Foundation

/// State behind the holder's banner for a pending phone-number transfer. The server is the source of
/// truth: every entry point (launch, return to the foreground, the WebSocket notice) calls `refresh()`,
/// which asks the server for the list and shows what it returns. The only action is cancelling.
///
/// Rules, each pinned by `PhoneTransferNoticeModelTests`:
///  - an empty list shows nothing;
///  - the device clock never removes an entry: whatever the server lists is shown, so a clock that runs
///    ahead cannot hide a live transfer from its holder;
///  - requests do not overlap: a `throttled` refresh (foreground, reconnect) asked while a request runs
///    shares it; one that must not be missed (the WebSocket notice, launch, retry, the read after a
///    cancel) queues ONE new request that starts after the running one ends, because the running one may
///    have started before the transfer existed. A request left over from before a `reset()` is never
///    shared: whoever asks after the reset gets a read of their own;
///  - `throttled` refreshes are skipped within `minRefreshInterval` (measured on a monotonic clock) of the
///    last request that started; an answer thrown away by a `reset()` does not count as a read;
///  - nothing is read while the app is locked (`setLocked`), and the state is dropped when it locks;
///  - a 404 on the list or on a cancel hides the entry, with no message;
///  - any other failure keeps the entry and raises a neutral `problem`, so the action can be retried;
///    a failed list refresh with nothing on screen stays silent, since there is nothing to retry;
///  - a rejected session (`BCryptoError.unauthorized`) clears the state silently;
///  - a cancelled entry never comes back, even if a list request started before the cancel answers later;
///  - an answer that arrives after `reset()` (a list or a cancel) changes nothing, and a failed cancel can
///    only raise `.cancelFailed` for the entry still on screen; every successful read clears the problem;
///  - the cancel flag is set at the first tap (`requestCancel()` is synchronous), so a second tap is ignored;
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
    private let uptime: @Sendable () -> TimeInterval
    private var refreshGeneration = 0
    /// Bumped by `reset()` only: tells apart an answer that belongs to the account or session that left.
    private var epoch = 0
    private var inFlightEpoch = 0
    private var locked = false
    private var cancelledIds: Set<String> = []
    private var inFlight: Task<Void, Never>?
    private var rerunRequested = false
    private var lastStartedAt: TimeInterval?

    public init(
        api: PhoneTransferApi,
        minRefreshInterval: TimeInterval = 30,
        uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.api = api
        self.minRefreshInterval = minRefreshInterval
        self.uptime = uptime
    }

    /// The entry to show: the one that expires first.
    public var current: PhoneTransferPending? {
        transfers.min { $0.expiresAt < $1.expiresAt }
    }

    /// Asks the server for the pending transfers and shows the result.
    public func refresh(throttled: Bool = false) async {
        guard !locked else { return }
        if let running = inFlight {
            // A request from before a reset belongs to someone else, and an unthrottled ask may be about
            // a transfer newer than the running request: both queue a request of their own.
            if !throttled || inFlightEpoch != epoch { rerunRequested = true }
            await running.value
            return
        }
        if throttled, let last = lastStartedAt, uptime() - last < minRefreshInterval { return }
        inFlightEpoch = epoch
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runRefreshes()
        }
        inFlight = task
        await task.value
    }

    /// The cancel button: the flag that disables it is set before this returns, so a second tap does
    /// nothing; the request itself runs in the background.
    public func requestCancel() {
        guard let target = beginCancel() else { return }
        Task { [weak self] in
            await self?.finishCancel(target)
        }
    }

    /// Cancels the entry on screen. On success (or a 404) the entry is hidden and the list is read
    /// again; on any other failure the entry stays and `problem` is `.cancelFailed`.
    public func cancel() async {
        guard let target = beginCancel() else { return }
        await finishCancel(target)
    }

    /// The screen is locked (true) or unlocked (false). Locking drops the state; while locked nothing is
    /// read. The caller asks for a read after unlocking.
    public func setLocked(_ value: Bool) {
        locked = value
        if value { reset() }
    }

    /// Drops everything: sign-out, wipe, app lock, expired session, change of account.
    public func reset() {
        epoch += 1
        refreshGeneration += 1
        transfers = []
        problem = nil
        isCancelling = false
        cancelledIds = []
        rerunRequested = false
        lastStartedAt = nil
    }

    private func beginCancel() -> PhoneTransferPending? {
        guard !isCancelling, let target = current else { return nil }
        isCancelling = true
        problem = nil
        return target
    }

    private func finishCancel(_ target: PhoneTransferPending) async {
        let startedIn = epoch
        let outcome = await cancelOnServer(id: target.id)
        // The account or session that asked is gone: its answer changes nothing.
        guard startedIn == epoch else { return }
        isCancelling = false
        switch outcome {
        case .gone:
            forget(id: target.id)
            await refresh()
        case .failed:
            if transfers.contains(where: { $0.id == target.id }) { problem = .cancelFailed }
        case .signedOut:
            reset()
        }
    }

    private func runRefreshes() async {
        repeat {
            rerunRequested = false
            inFlightEpoch = epoch
            lastStartedAt = uptime()
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
            problem = nil
        } catch {
            guard generation == refreshGeneration else { return }
            if Self.isNotFound(error) {
                transfers = []
                problem = nil
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
