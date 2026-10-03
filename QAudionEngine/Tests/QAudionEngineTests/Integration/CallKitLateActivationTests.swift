import XCTest
@testable import QAudionEngine

/// W-CALLERBUSY (2026-10-03, review of #169) — an audio-session activation that lands AFTER the call it was made for
/// has already ended.
///
/// `CallKitProvider.provider(_:perform: CXStartCallAction)` fulfils the action and then spawns an unstructured `Task`
/// that runs `activateAudioSession`. In the incident race (`call_busy` at +577 ms, CallKit's start fulfilled at about
/// +691 ms) the busy teardown can reach `reportCallEnded` (and `consumeEndBalance`) BEFORE that Task's
/// `setActive(true)` and `markAudioSelfActivated`. Before the fix the end balance had been decided without the
/// activation and nothing ever paid it back: the shared `RTCAudioSession` stayed active with `activationCount` one too
/// high (the W-DRAINACTIVATION class), and the late `onAudioSessionActivated` set `CallService.audioSessionActive =
/// true` after `endCall` had cleared it, so the REDIAL (busy, then redial: the owner's scenario) started with the W464
/// gate already satisfied.
///
/// `CallKitProvider` is behind `#if canImport(CallKit) && os(iOS)` and owns a live `CXProvider`, so the ordering is
/// pinned on the ledger (`markAudioSelfActivatedUnlessEnded`, the one atomic decision it makes) and replayed through a
/// model that mirrors the provider's success branch and `reportCallEnded`; `CallerBusyWiringTests` pins that the
/// provider's code has exactly that shape.
final class CallKitLateActivationTests: XCTestCase {

    // MARK: - the ledger decision

    /// The normal order: the activation lands first. It is marked, the callbacks run, and the end report balances it.
    func testAnActivationBeforeTheEndIsOwedAndBalancedByTheEnd() {
        let ledger = CallKitCallLedger()
        let uuid = UUID()
        XCTAssertEqual(ledger.markAudioSelfActivatedUnlessEnded(uuid), .owed)
        let end = ledger.consumeEndBalance(uuid)
        XCTAssertTrue(end.selfActivated, "the end of the call pays back its own activation")
    }

    /// The incident order: the end report runs first. The activation is recognised as late, nothing is marked.
    func testAnActivationAfterTheEndIsLateAndMarksNothing() {
        let ledger = CallKitCallLedger()
        let uuid = UUID()
        XCTAssertFalse(ledger.consumeEndBalance(uuid).selfActivated, "nothing was activated yet")

        XCTAssertEqual(ledger.markAudioSelfActivatedUnlessEnded(uuid), .callAlreadyEnded)

        // Nothing is owed by a later (duplicate) end report of the same call...
        XCTAssertFalse(ledger.consumeEndBalance(uuid).selfActivated)
        // ...and the process-wide legacy flag was not set, so the NEXT, unrelated call does not consume the late
        // activation as its own self-activation.
        XCTAssertFalse(ledger.consumeEndBalance(UUID()).selfActivated, "the late activation leaked into the legacy flag")
    }

    /// Same, for a native-SRTP call (its mark is keyed by its own uuid).
    func testALateActivationOfANativeCallMarksNothingUnderItsKey() {
        let ledger = CallKitCallLedger()
        let uuid = UUID()
        ledger.recordNativeBalance(uuid)                     // `perform(CXStartCallAction)` records it first
        XCTAssertFalse(ledger.consumeEndBalance(uuid).selfActivated)

        XCTAssertEqual(ledger.markAudioSelfActivatedUnlessEnded(uuid), .callAlreadyEnded)

        let again = ledger.consumeEndBalance(uuid)
        XCTAssertFalse(again.selfActivated, "no mark was left under the native key")
        XCTAssertTrue(again.duplicateNative, "a repeated report of a balanced native call stays a no-op")
        XCTAssertFalse(ledger.consumeEndBalance(UUID()).selfActivated, "nor under the legacy flag")
    }

    /// The redial's own uuid is unaffected by the previous call's end.
    func testTheRedialsActivationIsOwedAfterThePreviousCallEnded() {
        let ledger = CallKitCallLedger()
        let first = UUID()
        let redial = UUID()
        _ = ledger.consumeEndBalance(first)
        XCTAssertEqual(ledger.markAudioSelfActivatedUnlessEnded(first), .callAlreadyEnded)

        XCTAssertEqual(ledger.markAudioSelfActivatedUnlessEnded(redial), .owed)
        XCTAssertTrue(ledger.consumeEndBalance(redial).selfActivated)
    }

    /// An activation with no uuid (a self-managed group call) cannot have ended: unchanged behaviour.
    func testAnActivationWithoutAUuidIsAlwaysOwed() {
        let ledger = CallKitCallLedger()
        _ = ledger.consumeEndBalance(UUID())
        XCTAssertEqual(ledger.markAudioSelfActivatedUnlessEnded(nil), .owed)
        XCTAssertTrue(ledger.consumeEndBalance(UUID()).selfActivated, "the process-wide flag was set, as before")
    }

    /// The memory of ended calls is bounded; a uuid that old is not a race this app can still be in, and it falls back to
    /// the previous behaviour (owed) rather than growing without limit.
    func testTheEndedMemoryIsBounded() {
        let ledger = CallKitCallLedger()
        let oldest = UUID()
        _ = ledger.consumeEndBalance(oldest)
        for _ in 0..<200 { _ = ledger.consumeEndBalance(UUID()) }
        XCTAssertEqual(ledger.markAudioSelfActivatedUnlessEnded(oldest), .owed)
        // The recent ones are still remembered.
        let recent = UUID()
        _ = ledger.consumeEndBalance(recent)
        XCTAssertEqual(ledger.markAudioSelfActivatedUnlessEnded(recent), .callAlreadyEnded)
    }

    /// A call closed by the reaper (`CallKitProvider.endAllOutstanding`, which reports the uuid ended without any
    /// `consumeEndBalance`) is also "ended": a start Task whose activation lands afterwards is balanced at once,
    /// not left one activation too high, and it marks nothing for the next call.
    func testAnActivationAfterTheReaperDrainIsLateAndMarksNothing() {
        let ledger = CallKitCallLedger()
        let reaped = UUID()
        ledger.recordOutstanding(reaped)
        XCTAssertEqual(ledger.drainOutstanding(), [reaped])

        XCTAssertEqual(ledger.markAudioSelfActivatedUnlessEnded(reaped), .callAlreadyEnded)
        XCTAssertFalse(ledger.consumeEndBalance(UUID()).selfActivated, "the late activation leaked into the legacy flag")
    }

    /// Only what the drain actually closed is marked: a call still open, and a uuid that was only suppressed
    /// (rejected, never reported), keep the normal behaviour.
    func testTheDrainMarksOnlyTheUuidsItClosed() {
        let ledger = CallKitCallLedger()
        let reaped = UUID()
        let suppressedOnly = UUID()
        ledger.recordOutstanding(reaped)
        ledger.recordRejected(suppressedOnly)
        _ = ledger.drainOutstanding()

        XCTAssertEqual(ledger.markAudioSelfActivatedUnlessEnded(reaped), .callAlreadyEnded)
        XCTAssertEqual(ledger.markAudioSelfActivatedUnlessEnded(suppressedOnly), .owed)
        let later = UUID()
        ledger.recordOutstanding(later)
        XCTAssertEqual(ledger.markAudioSelfActivatedUnlessEnded(later), .owed, "recorded after the drain: still open")
    }

    /// The drain shares the end report's bounded memory and never duplicates an entry: a uuid the end report already
    /// marked, drained afterwards, does not grow the list and so cannot push the oldest entry out early.
    func testTheDrainDoesNotDuplicateAnEntryTheEndReportAlreadyMade() {
        let ledger = CallKitCallLedger()
        let full = (0..<128).map { _ in UUID() }               // exactly the capacity, oldest first
        for uuid in full { _ = ledger.consumeEndBalance(uuid) }
        ledger.recordOutstanding(full[64])                     // an end report that raced the drain's snapshot
        _ = ledger.drainOutstanding()

        XCTAssertEqual(ledger.markAudioSelfActivatedUnlessEnded(full[0]), .callAlreadyEnded,
                       "the oldest entry is still remembered: the re-mark did not grow the list")
        XCTAssertEqual(ledger.markAudioSelfActivatedUnlessEnded(full[64]), .callAlreadyEnded)
    }

    /// Same 128 cap as the end report: of 200 uuids closed by one drain, exactly 128 are remembered (a drain has no
    /// order among its uuids, so which 128 is not pinned).
    func testTheDrainIsCappedLikeTheEndReport() {
        let ledger = CallKitCallLedger()
        let many = (0..<200).map { _ in UUID() }
        for uuid in many { ledger.recordOutstanding(uuid) }
        XCTAssertEqual(ledger.drainOutstanding().count, 200)

        let remembered = many.filter { ledger.markAudioSelfActivatedUnlessEnded($0) == .callAlreadyEnded }.count
        XCTAssertEqual(remembered, 128)
    }

    /// Whichever of the two runs second sees the other, from any thread: never both "owed" and "ended".
    func testConcurrentActivationAndEndAreNeverBothMissed() {
        /// One slot per side, written from one thread each.
        final class Slots: @unchecked Sendable {
            var outcome: CallKitCallLedger.SelfActivationOutcome?
            var endBalance: CallKitCallLedger.EndBalance?
        }
        for _ in 0..<200 {
            let ledger = CallKitCallLedger()
            let uuid = UUID()
            let slots = Slots()
            DispatchQueue.concurrentPerform(iterations: 2) { side in
                if side == 0 {
                    slots.outcome = ledger.markAudioSelfActivatedUnlessEnded(uuid)
                } else {
                    slots.endBalance = ledger.consumeEndBalance(uuid)
                }
            }
            // Exactly one side owes the balance: the end paid it (activation first), or the activation pays it itself.
            let paidByEnd = slots.endBalance?.selfActivated == true
            let paidByActivation = slots.outcome == .callAlreadyEnded
            XCTAssertNotEqual(paidByEnd, paidByActivation, "the activation must be balanced by exactly one side")
        }
    }

    // MARK: - the incident, replayed

    /// What the provider's success branch and `reportCallEnded` do to the shared audio session, and what the app side
    /// (`CallService.audioSessionActive`, the W464 gate) hears from the activation callback. Mirrors
    /// `CallKitProvider.activateAudioSession` / `reportCallEnded`, which `CallerBusyWiringTests` pins.
    private final class AudioSide {
        let ledger = CallKitCallLedger()
        /// `RTCAudioSession.activationCount`.
        var activationCount = 0
        /// `CallService.audioSessionActive`: set by the activation callback, cleared by the call teardown.
        var audioSessionActive = false
        var activationCallbacks = 0

        /// `activateAudioSession`, after a successful `setActive(true)`.
        func activate(uuid: UUID) {
            activationCount += 1
            switch ledger.markAudioSelfActivatedUnlessEnded(uuid) {
            case .owed:
                activationCallbacks += 1
                audioSessionActive = true          // onAudioSessionActivated -> handleAudioSessionActivated
            case .callAlreadyEnded:
                activationCount -= 1               // the balancing setActive(false), no callback
            }
        }

        /// `reportCallEnded`'s audio part: the legacy one-uuid-one-balance case.
        func reportCallEnded(uuid: UUID) {
            if ledger.consumeEndBalance(uuid).selfActivated { activationCount -= 1 }
        }

        /// `AppState.endCall` -> `callService.endCall()`: the session is no longer active for the app.
        func teardown() { audioSessionActive = false }

        /// `CallKitProvider.endAllOutstanding`: the reaper reports every drained uuid ended with no end balance.
        func reapOutstanding() { _ = ledger.drainOutstanding() }
    }

    /// The incident: the busy teardown (report + teardown) runs, THEN the start action's Task activates the session.
    /// The session ends balanced, the app is told nothing, and the redial's W464 gate is not pre-satisfied.
    func testBusyThenLateActivationLeavesTheSessionBalancedAndTheRedialGateClosed() {
        let s = AudioSide()
        let first = UUID()

        s.teardown()                                     // endCall: audioSessionActive cleared
        s.reportCallEnded(uuid: first)                   // the busy settle ended the CallKit call...
        s.activate(uuid: first)                          // ...and only now does the start Task activate

        XCTAssertEqual(s.activationCount, 0, "the late activation was balanced at once (no +1 left behind)")
        XCTAssertFalse(s.audioSessionActive, "no onAudioSessionActivated after the teardown cleared it")
        XCTAssertEqual(s.activationCallbacks, 0)

        // The redial: its gate (`audioSessionActive`) is closed until ITS activation, then opens.
        let redial = UUID()
        XCTAssertFalse(s.audioSessionActive, "the redial must not start with the W464 gate already satisfied")
        s.activate(uuid: redial)
        XCTAssertTrue(s.audioSessionActive)
        XCTAssertEqual(s.activationCount, 1)
        s.teardown()
        s.reportCallEnded(uuid: redial)
        XCTAssertEqual(s.activationCount, 0, "the redial balances normally")
    }

    /// The reaper closes the call (no end balance), THEN the start Task activates: balanced at once, gate closed.
    func testReapedCallThenLateActivationLeavesTheSessionBalanced() {
        let s = AudioSide()
        let uuid = UUID()
        s.ledger.recordOutstanding(uuid)                 // the outgoing uuid, recorded after `request` returned
        s.teardown()
        s.reapOutstanding()
        s.activate(uuid: uuid)

        XCTAssertEqual(s.activationCount, 0)
        XCTAssertFalse(s.audioSessionActive)
        XCTAssertEqual(s.activationCallbacks, 0)
    }

    /// The normal order is untouched: activation, then the end report.
    func testANormalCallStaysBalanced() {
        let s = AudioSide()
        let uuid = UUID()
        s.activate(uuid: uuid)
        XCTAssertEqual(s.activationCount, 1)
        XCTAssertTrue(s.audioSessionActive)
        s.teardown()
        s.reportCallEnded(uuid: uuid)
        XCTAssertEqual(s.activationCount, 0)
        XCTAssertEqual(s.activationCallbacks, 1)
    }

    /// Three busy dials of the incident, each with the late activation: nothing accumulates.
    func testThreeBusyDialsWithLateActivationsLeaveNoActivationBehind() {
        let s = AudioSide()
        for _ in 0..<3 {
            let uuid = UUID()
            s.teardown()
            s.reportCallEnded(uuid: uuid)
            s.activate(uuid: uuid)
            XCTAssertEqual(s.activationCount, 0)
            XCTAssertFalse(s.audioSessionActive)
        }
        XCTAssertEqual(s.activationCallbacks, 0)
    }
}
