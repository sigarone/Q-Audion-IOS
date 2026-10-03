import Foundation
import QAudionEngine

/// State machine behind the safety-number card of `ContactDetailScreen`
/// (loading -> loaded | failed), kept free of SwiftUI so it can be unit tested.
///
/// Why it exists (bug reports 2548ffa3 and 3b24290e): the screen ran
/// `PeerTrustEvaluator.evaluate` once per visit and rendered its result as
/// `.unverified`, which the card draws as "Calcolo del trust in corso…". But
/// `evaluate` degrades EVERY failure (offline, server error, unreachable peer
/// key endpoint) to that same `.unverified`, so a failed fetch looked exactly
/// like a computation that never finished, with no way out until the user left
/// and re-entered the screen.
///
/// Rules:
///   - `loading` is only ever the state of an evaluation that is actually in
///     flight, and it ends: a deadline (`timeout`) turns a hung request into
///     `failed(.timeout)`, even if the evaluator itself ignores cancellation.
///   - `failed` carries the reason and is left by `retry()` (the card's
///     "Riprova") or automatically when the persistent socket comes back
///     (`connectionStateChanged`).
///   - a re-evaluation after a local action (mark verified / accept new
///     identity, or the screen re-appearing) keeps showing the previous result
///     instead of flashing the spinner.
///   - the trust / TOFU decision is NOT made here: the evaluator is injected and
///     this type only reports what it returned or threw.
///
/// The view drives it with `.task(id: runKey)`: `run` is the evaluation, and
/// `retry` / `refresh` / a reconnect bump `runToken`, which re-keys the task.
/// Structured concurrency then cancels a superseded or abandoned run for free.
@MainActor
final class TrustEvaluationModel: ObservableObject {

    enum Phase: Equatable {
        case loading
        case loaded(PeerTrustEvaluator.Evaluation)
        case failed(PeerTrustEvaluator.EvaluationError)
    }

    /// Evaluates one peer; throws `PeerTrustEvaluator.EvaluationError` (any other
    /// error is treated as `.unreachable`).
    typealias Evaluator = @MainActor (String) async throws -> PeerTrustEvaluator.Evaluation

    @Published private(set) var phase: Phase = .loading
    /// Bumped whenever a (re)run is requested; the view includes it in the
    /// `.task(id:)` key.
    @Published private(set) var runToken: Int = 0

    /// Wall-clock deadline for one evaluation. The fetch underneath has a 15 s
    /// request timeout, but that is an idle timeout (a zombie connection can
    /// outlive it, see `BCryptoKmsClient.fetchUserIdentityKeyOutcome`), so the
    /// screen enforces its own.
    private let timeout: TimeInterval
    /// Set when the persistent socket (re)authenticated while an evaluation was
    /// in flight: if that evaluation then fails, it ran against the old network,
    /// so it is retried once instead of waiting for a second reconnect.
    private var reconnectedWhileRunning = false

    init(timeout: TimeInterval = 20) {
        self.timeout = timeout
    }

    /// The last successful evaluation, nil while loading or after a failure.
    var evaluation: PeerTrustEvaluator.Evaluation? {
        if case .loaded(let evaluation) = phase { return evaluation }
        return nil
    }

    var failure: PeerTrustEvaluator.EvaluationError? {
        if case .failed(let error) = phase { return error }
        return nil
    }

    // MARK: - Running

    /// Evaluate `peerUserId` once. Returns when the evaluation finished, failed,
    /// timed out, or this task was cancelled (a cancelled run leaves the
    /// published state alone; whoever cancelled it owns the next transition).
    func run(peerUserId: String, evaluator: @escaping Evaluator) async {
        // Keep a previous result on screen while re-evaluating it; show the
        // spinner for the first evaluation and after a failure.
        if case .loaded = phase {} else { phase = .loading }
        reconnectedWhileRunning = false

        let timeout = self.timeout
        let outcome = await DeadlineRace.run(timeout: timeout) {
            try await evaluator(peerUserId)
        }
        if Task.isCancelled { return }

        switch outcome {
        case .success(let evaluation):
            phase = .loaded(evaluation)
        case .failure(let error):
            if reconnectedWhileRunning {
                reconnectedWhileRunning = false
                retry()
                return
            }
            phase = .failed(error as? PeerTrustEvaluator.EvaluationError ?? .unreachable)
        }
    }

    /// The card's "Riprova": go back to loading and re-run.
    func retry() {
        phase = .loading
        runToken += 1
    }

    /// Re-evaluate after a local action changed the inputs (mark verified,
    /// accept the new identity). The current result stays visible meanwhile.
    func refresh() {
        runToken += 1
    }

    /// Automatic retry on reconnect: a failed evaluation (offline, server
    /// unreachable, timeout) is run again as soon as the persistent socket is
    /// authenticated. A loaded result and other socket states are left alone, so
    /// this never restarts a healthy evaluation; during a run it only arms the
    /// one-shot retry described on `reconnectedWhileRunning`.
    func connectionStateChanged(to state: ConnectionState) {
        guard state == .authenticated else { return }
        switch phase {
        case .failed:
            retry()
        case .loading:
            reconnectedWhileRunning = true
        case .loaded:
            break
        }
    }

    // MARK: - User-facing text

    /// Italian message shown under the card header for a failed evaluation.
    static func message(for error: PeerTrustEvaluator.EvaluationError) -> String {
        switch error {
        case .offline:
            return String(localized: "trust.error.offline", defaultValue: "Sei offline. Non è stato possibile calcolare il trust del contatto.", comment: "Contact trust card — the evaluation failed because the device has no network")
        case .unreachable:
            return String(localized: "trust.error.unreachable", defaultValue: "Impossibile contattare il server per recuperare l'identità del contatto.", comment: "Contact trust card — the evaluation failed because the identity key request failed")
        case .timeout:
            return String(localized: "trust.error.timeout", defaultValue: "Il server non ha risposto in tempo.", comment: "Contact trust card — the evaluation did not finish within the deadline")
        }
    }
}

/// Runs an async operation against a wall-clock deadline and returns whichever
/// finishes first, WITHOUT waiting for the loser. A `TaskGroup` race would wait
/// for the losing child, so an operation that ignores cancellation would hold
/// the "timeout" until it returned on its own, which defeats the deadline.
/// Here the loser is cancelled and abandoned; its late result is dropped.
enum DeadlineRace {

    typealias Outcome = Result<PeerTrustEvaluator.Evaluation, Error>

    @MainActor
    static func run(timeout: TimeInterval,
                    _ operation: @escaping @MainActor () async throws -> PeerTrustEvaluator.Evaluation) async -> Outcome {
        let gate = Gate()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
                gate.install(continuation)
                gate.track(Task { @MainActor in
                    do {
                        let evaluation = try await operation()
                        gate.finish(.success(evaluation))
                    } catch {
                        gate.finish(.failure(error))
                    }
                })
                gate.track(Task { @MainActor in
                    let nanoseconds = UInt64(max(0, timeout) * 1_000_000_000)
                    do {
                        try await Task.sleep(nanoseconds: nanoseconds)
                    } catch {
                        return // cancelled: the other side already won
                    }
                    gate.finish(.failure(PeerTrustEvaluator.EvaluationError.timeout))
                })
            }
        } onCancel: {
            gate.finish(.failure(CancellationError()))
        }
    }

    /// Resolves the continuation exactly once, whichever side gets there first
    /// (including a result that arrives before the continuation is installed,
    /// or a cancellation that fires before the child tasks exist).
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Outcome, Never>?
        private var outcome: Outcome?
        private var finished = false
        private var tasks: [Task<Void, Never>] = []

        func install(_ continuation: CheckedContinuation<Outcome, Never>) {
            lock.lock()
            if let outcome {
                lock.unlock()
                continuation.resume(returning: outcome)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }

        func track(_ task: Task<Void, Never>) {
            lock.lock()
            let alreadyFinished = finished
            if !alreadyFinished { tasks.append(task) }
            lock.unlock()
            if alreadyFinished { task.cancel() }
        }

        func finish(_ result: Outcome) {
            lock.lock()
            if finished {
                lock.unlock()
                return
            }
            finished = true
            outcome = result
            let waiting = continuation
            continuation = nil
            let toCancel = tasks
            tasks = []
            lock.unlock()
            waiting?.resume(returning: result)
            toCancel.forEach { $0.cancel() }
        }
    }
}
