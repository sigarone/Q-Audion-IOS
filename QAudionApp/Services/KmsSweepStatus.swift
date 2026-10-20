import Foundation

/// The outcome of the KMS sweeps, for the KMS row of Key management and its "Aggiorna" action.
///
/// Every sweep records here, whoever started it: the first one after sign-in, the periodic one, the one the
/// server's `kms_key_available` event starts, and the one the user asks for. Two sweeps can overlap; the screen
/// shows "running" until the last of them ends.
@MainActor
final class KmsSweepStatus: ObservableObject {

    static let shared = KmsSweepStatus()

    /// What the KMS row says.
    enum State: Equatable {
        /// No sweep has finished since the app started.
        case idle
        case running
        case succeeded(at: Date)
        case failed(at: Date)
    }

    @Published private(set) var isRunning: Bool = false
    @Published private(set) var lastFinishedAt: Date?
    @Published private(set) var lastSucceeded: Bool = false

    private var runningSweeps = 0

    var state: State {
        if isRunning { return .running }
        guard let lastFinishedAt else { return .idle }
        return lastSucceeded ? .succeeded(at: lastFinishedAt) : .failed(at: lastFinishedAt)
    }

    func sweepStarted() {
        runningSweeps += 1
        isRunning = true
    }

    func sweepFinished(succeeded: Bool, at date: Date = Date()) {
        runningSweeps = max(0, runningSweeps - 1)
        isRunning = runningSweeps > 0
        lastFinishedAt = date
        lastSucceeded = succeeded
    }
}
