import XCTest
@testable import QAudionApp
import QAudionEngine

/// State machine behind the contact-detail safety-number card (bug reports
/// 2548ffa3 and 3b24290e: the card stayed on "Calcolo del trust in corso…"
/// forever after a failed identity-key fetch).
///
/// Pure: the evaluator is injected, so no Keychain, no ContactsStore, no
/// network. The trust / TOFU decision itself (`PeerTrustEvaluator`) is NOT under
/// test here; these tests pin only how its result or failure is surfaced:
/// loading -> loaded | failed, the deadline, "Riprova", the automatic retry on
/// reconnect and the "keep the old result while re-evaluating" rule.
@MainActor
final class TrustEvaluationModelTests: XCTestCase {

    private typealias Model = TrustEvaluationModel
    private typealias Failure = PeerTrustEvaluator.EvaluationError

    /// Mutable record shared with the (implicitly Sendable) evaluator closures.
    private final class Recorder {
        var userId: String?
        var phase: Model.Phase?
    }

    private func makeEvaluation(
        _ state: TrustSafetyNumberState = .identityPinnedTofu,
        key: UInt8 = 7
    ) -> PeerTrustEvaluator.Evaluation {
        PeerTrustEvaluator.Evaluation(
            state: state,
            safetyNumber: .mock,
            verifiedAt: nil,
            verificationMethod: nil,
            peerIkEdPub: Data(repeating: key, count: 32)
        )
    }

    // MARK: - Basic transitions

    func test_initialPhase_isLoading_withNoResult() {
        let model = Model()
        XCTAssertEqual(model.phase, .loading)
        XCTAssertNil(model.evaluation)
        XCTAssertNil(model.failure)
        XCTAssertEqual(model.runToken, 0)
    }

    func test_run_success_publishesLoadedEvaluation() async {
        let model = Model()
        let expected = makeEvaluation(.userVerified)
        await model.run(peerUserId: "peer-1") { _ in expected }
        XCTAssertEqual(model.phase, .loaded(expected))
        XCTAssertEqual(model.evaluation, expected)
        XCTAssertNil(model.failure)
    }

    func test_run_passesThePeerUserIdToTheEvaluator() async {
        let model = Model()
        let recorder = Recorder()
        let evaluation = makeEvaluation()
        await model.run(peerUserId: "peer-xyz") { userId in
            recorder.userId = userId
            return evaluation
        }
        XCTAssertEqual(recorder.userId, "peer-xyz")
    }

    func test_run_isLoadingWhileTheEvaluatorIsInFlight() async {
        let model = Model()
        let recorder = Recorder()
        let evaluation = makeEvaluation()
        await model.run(peerUserId: "p") { _ in
            recorder.phase = model.phase
            return evaluation
        }
        XCTAssertEqual(recorder.phase, .loading)
    }

    func test_run_offlineFailure_isSurfacedAsFailed_notAsLoading() async {
        let model = Model()
        await model.run(peerUserId: "p") { _ in throw Failure.offline }
        XCTAssertEqual(model.phase, .failed(.offline))
        XCTAssertEqual(model.failure, .offline)
        XCTAssertNil(model.evaluation)
    }

    func test_run_unreachableFailure_isSurfacedAsFailed() async {
        let model = Model()
        await model.run(peerUserId: "p") { _ in throw Failure.unreachable }
        XCTAssertEqual(model.phase, .failed(.unreachable))
    }

    func test_run_anyOtherError_isTreatedAsUnreachable() async {
        let model = Model()
        await model.run(peerUserId: "p") { _ in throw URLError(.notConnectedToInternet) }
        XCTAssertEqual(model.phase, .failed(.unreachable))

        let second = Model()
        await second.run(peerUserId: "p") { _ in throw CancellationError() }
        XCTAssertEqual(second.phase, .failed(.unreachable),
                       "a cancelled request that the OUTER task did not cancel (a network-path change) is a retriable failure")
    }

    // MARK: - Deadline

    /// An evaluator that ignores cancellation: it parks on a continuation that nothing but `release` resumes.
    /// Main-actor only, like the evaluator closures that call it.
    @MainActor
    private final class ParkedEvaluator {
        private(set) var released = false
        private var releasedWith: PeerTrustEvaluator.Evaluation?
        private var continuation: CheckedContinuation<PeerTrustEvaluator.Evaluation, Error>?

        func evaluate() async throws -> PeerTrustEvaluator.Evaluation {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<PeerTrustEvaluator.Evaluation, Error>) in
                if let releasedWith = self.releasedWith {
                    continuation.resume(returning: releasedWith)   // released before it parked
                } else {
                    self.continuation = continuation
                }
            }
        }

        func release(with evaluation: PeerTrustEvaluator.Evaluation) {
            released = true
            releasedWith = evaluation
            continuation?.resume(returning: evaluation)
            continuation = nil
        }
    }

    /// Deterministic: no wall-clock bound. The evaluator is released only AFTER `run` returned, so `run` returning
    /// at all proves the deadline did not wait for an evaluator that ignores cancellation. (An earlier version bounded
    /// the elapsed time at 0.45 s, which a loaded runner can exceed: it failed after 502 s on a starved CI host.)
    func test_run_timesOut_whenTheEvaluatorHangs_evenIfItIgnoresCancellation() async throws {
        let model = Model(timeout: 0.05)
        let late = makeEvaluation()
        let parked = ParkedEvaluator()
        let abandonedEnded = expectation(description: "the abandoned evaluator ran to its end")
        // Safety net for a regression only: without it a deadline that waits for the evaluator would hang the job.
        // It is far longer than any healthy run and is cancelled as soon as `run` returns.
        let watchdog = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            parked.release(with: late)
        }
        await model.run(peerUserId: "p") { _ in
            defer { abandonedEnded.fulfill() }
            return try await parked.evaluate()
        }
        watchdog.cancel()
        XCTAssertFalse(parked.released, "the deadline must not wait for an evaluator that ignores cancellation")
        XCTAssertEqual(model.phase, .failed(.timeout))

        // The abandoned evaluator finishing later must not overwrite the failure.
        parked.release(with: late)
        await fulfillment(of: [abandonedEnded], timeout: 30)
        XCTAssertEqual(model.phase, .failed(.timeout))
    }

    func test_run_fastEvaluator_beatsTheDeadline() async {
        let model = Model(timeout: 5)
        let expected = makeEvaluation()
        await model.run(peerUserId: "p") { _ in expected }
        XCTAssertEqual(model.phase, .loaded(expected))
    }

    // MARK: - Riprova

    func test_retry_afterFailure_returnsToLoading_andRequestsANewRun() async {
        let model = Model()
        await model.run(peerUserId: "p") { _ in throw Failure.unreachable }
        let tokenBefore = model.runToken

        model.retry()

        XCTAssertEqual(model.phase, .loading)
        XCTAssertEqual(model.runToken, tokenBefore + 1,
                       "the view keys its .task on runToken, so a retry must change it")
    }

    func test_retry_thenRun_recoversToLoaded() async {
        let model = Model()
        await model.run(peerUserId: "p") { _ in throw Failure.offline }
        XCTAssertEqual(model.phase, .failed(.offline))

        model.retry()
        let expected = makeEvaluation(.identityPinnedTofu)
        await model.run(peerUserId: "p") { _ in expected }

        XCTAssertEqual(model.phase, .loaded(expected))
    }

    // MARK: - Automatic retry on reconnect

    func test_reconnect_whileFailed_retriesAutomatically() async {
        for failure in [Failure.offline, .unreachable, .timeout] {
            let model = Model()
            await model.run(peerUserId: "p") { _ in throw failure }
            let tokenBefore = model.runToken

            model.connectionStateChanged(to: .authenticated)

            XCTAssertEqual(model.phase, .loading, "failure \(failure)")
            XCTAssertEqual(model.runToken, tokenBefore + 1, "failure \(failure)")
        }
    }

    func test_nonAuthenticatedSocketStates_doNotRetryAFailure() async {
        let model = Model()
        await model.run(peerUserId: "p") { _ in throw Failure.offline }
        let tokenBefore = model.runToken

        let otherStates: [ConnectionState] = [.disconnected, .connecting, .connected]
        for state in otherStates {
            model.connectionStateChanged(to: state)
        }

        XCTAssertEqual(model.phase, .failed(.offline))
        XCTAssertEqual(model.runToken, tokenBefore)
    }

    func test_reconnect_whileLoaded_leavesTheResultAlone() async {
        let model = Model()
        let expected = makeEvaluation(.userVerified)
        await model.run(peerUserId: "p") { _ in expected }
        let tokenBefore = model.runToken

        model.connectionStateChanged(to: .authenticated)

        XCTAssertEqual(model.phase, .loaded(expected))
        XCTAssertEqual(model.runToken, tokenBefore)
    }

    func test_reconnectDuringARun_thatThenFails_retriesOnce() async {
        let model = Model()
        await model.run(peerUserId: "p") { _ in
            // The socket re-authenticates while this request is still in flight,
            // then the request (which started on the old network) fails.
            model.connectionStateChanged(to: .authenticated)
            throw Failure.unreachable
        }
        XCTAssertEqual(model.phase, .loading, "retried instead of showing a failure that the reconnect already fixed")
        XCTAssertEqual(model.runToken, 1)

        // The retry's own failure is NOT retried again (no loop).
        await model.run(peerUserId: "p") { _ in throw Failure.unreachable }
        XCTAssertEqual(model.phase, .failed(.unreachable))
        XCTAssertEqual(model.runToken, 1)
    }

    func test_reconnectDuringARun_thatSucceeds_isIgnored() async {
        let model = Model()
        let expected = makeEvaluation()
        await model.run(peerUserId: "p") { _ in
            model.connectionStateChanged(to: .authenticated)
            return expected
        }
        XCTAssertEqual(model.phase, .loaded(expected))
        XCTAssertEqual(model.runToken, 0)
    }

    // MARK: - Re-evaluation after a local action

    func test_refresh_keepsThePreviousResultVisibleWhileReevaluating() async {
        let model = Model()
        let first = makeEvaluation(.identityPinnedTofu)
        await model.run(peerUserId: "p") { _ in first }

        model.refresh()
        XCTAssertEqual(model.runToken, 1)
        XCTAssertEqual(model.phase, .loaded(first), "no spinner flash after mark-verified")

        let second = makeEvaluation(.userVerified)
        let recorder = Recorder()
        await model.run(peerUserId: "p") { _ in
            recorder.phase = model.phase
            return second
        }
        XCTAssertEqual(recorder.phase, .loaded(first))
        XCTAssertEqual(model.phase, .loaded(second))
    }

    func test_refresh_thatFails_showsTheFailure_notAStaleResult() async {
        let model = Model()
        await model.run(peerUserId: "p") { _ in self.makeEvaluation() }

        model.refresh()
        await model.run(peerUserId: "p") { _ in throw Failure.offline }

        XCTAssertEqual(model.phase, .failed(.offline))
        XCTAssertNil(model.evaluation)
    }

    // MARK: - Cancellation

    func test_cancelledRun_publishesNeitherAResultNorAFailure() async throws {
        let model = Model()
        let task = Task { @MainActor in
            await model.run(peerUserId: "p") { _ in
                try await Task.sleep(nanoseconds: 10_000_000_000)
                return self.makeEvaluation()
            }
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        await task.value

        XCTAssertEqual(model.phase, .loading,
                       "a superseded or abandoned run must leave the next transition to whoever cancelled it")
    }

    // MARK: - Messages

    func test_failureMessages_areNonEmptyAndDistinct() {
        let messages = [Failure.offline, .unreachable, .timeout].map { Model.message(for: $0) }
        XCTAssertTrue(messages.allSatisfy { !$0.isEmpty })
        XCTAssertEqual(Set(messages).count, messages.count)
    }
}
