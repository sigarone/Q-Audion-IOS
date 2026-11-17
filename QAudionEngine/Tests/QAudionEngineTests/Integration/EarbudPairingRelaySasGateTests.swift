import XCTest
@testable import QAudionEngine

/// CL-2.2: `EarbudPairingRelay` writes PAIR_FIN only after a person has confirmed the pairing words.
///
/// The gate used to be `isConfirmed: { _ in true }` at every call site and the default of the parameter, so
/// the confirmation never happened. These tests drive the relay against a fake earbud and pin what the
/// Android `EarbudPairingRelaySasGateTest` pins: a "no", no answer within the timeout, or a cancelled task all end
/// the pairing without a PAIR_FIN, and the result says the link must be dropped before a retry.
final class EarbudPairingRelaySasGateTests: XCTestCase {

    // MARK: - Fakes

    private final class Recorder<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [T] = []
        func append(_ v: T) { lock.lock(); values.append(v); lock.unlock() }
        var all: [T] { lock.lock(); defer { lock.unlock() }; return values }
    }

    private enum FakeError: Error { case boom }

    /// An earbud that answers PAIR_BEGIN, returns a canned PAIR_RESP and records what is written to PAIR_FIN.
    private final class FakeEarbud: EarbudPairingGattProxy, @unchecked Sendable {
        var isConnected: Bool = true
        var failPairBegin = false
        var failPairResp = false
        var failPairFin = false
        /// When set, every pairing operation runs inside it, as the real client's operations run inside `opGate`.
        var gate: EarbudSerialGate?
        /// When set, the earbud's answer to PAIR_FIN comes when this returns. It is waited for the way
        /// `IOSEarbudGattProxy.writeChar` waits for the answer to a write (a continuation): a caller that is
        /// cancelled meanwhile is NOT interrupted.
        var pairFinAnswer: (@Sendable () async -> Void)?
        /// The earbud's answer to PAIR_FIN is an error (the frame has been written all the same).
        var pairFinAnswerFails = false
        var pairResp: Data
        let pairBeginWrites = Recorder<Data>()
        let pairFinWrites = Recorder<Data>()

        init(pairResp: Data) { self.pairResp = pairResp }

        func startKeyImport(pkg: Data, popInputs: Data) async throws -> KeyImportOutcome { .err("unused") }
        func readAttestPop() async throws -> Data { Data() }
        private func gated<T>(_ body: () async throws -> T) async throws -> T {
            if let gate = gate { return try await gate.run(body) }
            return try await body()
        }
        func writePairBegin(_ payload: Data) async throws {
            try await gated {
                if self.failPairBegin { throw FakeError.boom }
                self.pairBeginWrites.append(payload)
            }
        }
        func readPairResp() async throws -> Data {
            try await gated {
                if self.failPairResp { throw FakeError.boom }
                return self.pairResp
            }
        }
        func writePairFin(_ confirm: Data) async throws {
            try await gated {
                if self.failPairFin { throw FakeError.boom }
                self.pairFinWrites.append(confirm)   // the frame has left the gate: the earbud has it
                if let answer = self.pairFinAnswer {
                    await Task.detached { await answer() }.value   // not cancelled with the caller
                }
                if self.pairFinAnswerFails { throw FakeError.boom }
            }
        }
        func writeFpAdvSeed(_ ctBind: Data) async throws {}
        func readFpAdv() async throws -> (fpAdv: Data, epoch: UInt64) { (Data(count: 32), 0) }
    }

    // MARK: - Fixtures

    /// The OTHER earbud (relayed by the other phone): the lesser eid, so the connected earbud is the RESPONDER.
    private let ownPkSe = Data((0..<32).map { UInt8(0x10 + $0) })
    private let ownMaterial = Data((0..<1568).map { UInt8($0 & 0xFF) })
    private let ownEid = Data((0..<32).map { UInt8(0x01 + $0) })
    /// The connected earbud's PAIR_RESP: pk_se || material (its ct_ee) || eid (the greater one).
    private let respPkSe = Data((0..<32).map { UInt8(0x60 + $0) })
    private let respMaterial = Data((0..<1568).map { UInt8(($0 * 3) & 0xFF) })
    private let respEid = Data((0..<32).map { UInt8(0x80 + $0) })

    private func makeEarbud() -> FakeEarbud {
        FakeEarbud(pairResp: respPkSe + respMaterial + respEid)
    }

    private var expectedPairId: Data {
        EarbudPairTranscript.pairId(eidA: ownEid, eidB: respEid)
    }

    private func pair(_ relay: EarbudPairingRelay,
                      isConfirmed: @escaping @Sendable (Data) async -> Bool) async -> EarbudPairingRelay.PairResult {
        await relay.pairWithPeer(
            peerPkSe: respPkSe, peerMaterial: respMaterial, peerEid: respEid,
            ownPkSe: ownPkSe, ownMaterial: ownMaterial, ownEid: ownEid,
            isConfirmed: isConfirmed)
    }

    // MARK: - The gate

    func testConfirmedPairingWritesPairFinOnceAndSucceeds() async {
        let earbud = makeEarbud()
        let asked = Recorder<Data>()
        let result = await pair(EarbudPairingRelay(gatt: earbud)) { pairId in
            asked.append(pairId)
            return true
        }

        guard case .success(let pairId, let ctEe) = result else { return XCTFail("expected success, got \(result)") }
        XCTAssertEqual(pairId, expectedPairId)
        XCTAssertEqual(asked.all, [expectedPairId], "the gate is asked once, with the pair_id the words come from")
        XCTAssertEqual(ctEe, respMaterial, "the connected earbud was the RESPONDER: its ct_ee is handed back")
        XCTAssertEqual(earbud.pairBeginWrites.all.count, 1)
        XCTAssertEqual(earbud.pairFinWrites.all.count, 1)
        // The PAIR_FIN the earbud checks: SHA-256(label || pair_id || eid_I || eid_R || SHA-256(ct_ee)).
        let expectedConfirm = EarbudPairTranscript.confirmHash(
            pairId: expectedPairId, eidI: ownEid, eidR: respEid, ctEe: respMaterial)
        XCTAssertEqual(earbud.pairFinWrites.all.first, expectedConfirm)
        XCTAssertFalse(result.needsFreshLink)
    }

    func testTheGateIsAskedWithThePairIdTheWordsAreDerivedFrom() async {
        let asked = Recorder<Data>()
        _ = await pair(EarbudPairingRelay(gatt: makeEarbud())) { pairId in
            asked.append(pairId)
            return false
        }
        guard let pairId = asked.all.first else { return XCTFail("the gate was not asked") }
        XCTAssertNotNil(EarbudPairTranscript.sasWords(pairId: pairId))
        XCTAssertEqual(pairId, expectedPairId)
    }

    func testADeclinedPairingNeverWritesPairFin() async {
        let earbud = makeEarbud()
        let result = await pair(EarbudPairingRelay(gatt: earbud)) { _ in false }

        guard case .sasRejected(let pairId) = result else { return XCTFail("expected sasRejected, got \(result)") }
        XCTAssertEqual(pairId, expectedPairId)
        XCTAssertEqual(earbud.pairFinWrites.all.count, 0, "PAIR_FIN is never written: the earbud seals nothing")
        XCTAssertTrue(result.needsFreshLink, "the earbud holds this attempt's PAIR_RESP until it disconnects")
    }

    func testNoAnswerWithinTheTimeoutIsARejection() async {
        let earbud = makeEarbud()
        let relay = EarbudPairingRelay(gatt: earbud, sasConfirmTimeout: 0.2)
        let started = Date()
        let result = await pair(relay) { _ in
            // A gate that only answers when it is cancelled, and then says "yes": too late to count.
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 20_000_000) }
            return true
        }

        guard case .sasRejected = result else { return XCTFail("expected sasRejected, got \(result)") }
        XCTAssertEqual(earbud.pairFinWrites.all.count, 0)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "the timeout ended the wait")
    }

    func testAnAnswerBeforeTheDeadlineWinsAndTheTimerIsCancelled() async {
        let earbud = makeEarbud()
        let relay = EarbudPairingRelay(gatt: earbud, sasConfirmTimeout: 30)
        let started = Date()
        let result = await pair(relay) { _ in
            try? await Task.sleep(nanoseconds: 50_000_000)
            return true
        }

        guard case .success = result else { return XCTFail("expected success, got \(result)") }
        XCTAssertEqual(earbud.pairFinWrites.all.count, 1)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "the 30 s timer did not hold the call open")
    }

    func testACancelledPairingIsARejectionAndWritesNothing() async {
        let earbud = makeEarbud()
        let relay = EarbudPairingRelay(gatt: earbud)
        let entered = Recorder<Bool>()
        let task = Task {
            await self.pair(relay) { _ in
                entered.append(true)
                while !Task.isCancelled { try? await Task.sleep(nanoseconds: 20_000_000) }
                return false
            }
        }
        // Wait until the relay reached the gate, then cancel (the screen went away, the link dropped).
        for _ in 0..<200 where entered.all.isEmpty { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(entered.all.isEmpty, "the relay reached the SAS gate")
        task.cancel()
        let result = await task.value

        guard case .sasRejected = result else { return XCTFail("expected sasRejected, got \(result)") }
        XCTAssertEqual(earbud.pairFinWrites.all.count, 0)
    }

    // MARK: - PAIR_FIN behind another operation of the shared client

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// Another user of the one GATT client (a DIAG poll, a key import) takes the gate and keeps it until `release`.
    private func holdGate(_ gate: EarbudSerialGate, until release: Flag) async -> Task<Void, Never> {
        let held = Flag()
        let task = Task {
            _ = try? await gate.run {
                held.set()
                while !release.isSet { try? await Task.sleep(nanoseconds: 2_000_000) }
            }
        }
        for _ in 0..<2000 where !held.isSet { try? await Task.sleep(nanoseconds: 1_000_000) }
        return task
    }

    /// After the person confirms, a PAIR_FIN that cannot get the client's gate within its timeout is reported as a
    /// failure. It used to stay in the gate's queue (the gate ignored cancellation, and the relay's task group waited
    /// for it), so it was written the moment the other operation ended: the earbud sealed a pairing the screen had
    /// reported as failed, and `pairWithPeer` itself did not return before then.
    func testAPairFinThatTimesOutBehindAnotherOperationIsNeverWrittenLate() async {
        let gate = EarbudSerialGate()
        let earbud = makeEarbud()
        earbud.gate = gate
        let relay = EarbudPairingRelay(gatt: earbud, finTimeout: 0.15)
        let release = Flag()
        let watchdogFired = Flag()
        // Safety net only: a gate that ignores cancellation would hold the call until the other operation ends.
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled { watchdogFired.set(); release.set() }
        }
        let holders = Recorder<Task<Void, Never>>()

        let result = await pair(relay) { _ in
            // The person taps "confirm"; right then a DIAG poll of the shared client takes the gate.
            holders.append(await self.holdGate(gate, until: release))
            return true
        }
        watchdog.cancel()

        XCTAssertFalse(watchdogFired.isSet, "pairWithPeer returned on its own timeout while the other operation still held the gate")
        guard case .defer(let reason, let cached) = result else { return XCTFail("expected defer, got \(result)") }
        XCTAssertTrue(reason.hasPrefix("pair_fin_failed"), reason)
        XCTAssertTrue(cached)
        XCTAssertTrue(result.needsFreshLink)

        release.set()
        for h in holders.all { await h.value }
        // Give a wrongly queued write the time it would need to run once the gate is free.
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(earbud.pairFinWrites.all.count, 0, "PAIR_FIN must not reach the earbud after the pairing was reported failed")
        let free = try? await gate.run { true }
        XCTAssertEqual(free, true, "the gate is free: the timed-out write left its queue")
    }

    func testAPairFinThatGetsTheGateInTimeIsStillWritten() async {
        let gate = EarbudSerialGate()
        let earbud = makeEarbud()
        earbud.gate = gate
        let result = await pair(EarbudPairingRelay(gatt: earbud, finTimeout: 5)) { _ in true }
        guard case .success = result else { return XCTFail("expected success, got \(result)") }
        XCTAssertEqual(earbud.pairFinWrites.all.count, 1)
    }

    // MARK: - PAIR_FIN already written when its time limit runs out

    /// One pairing in which another operation holds the client's gate when the person confirms, lets go of it well
    /// inside the PAIR_FIN's 0.3 s limit (so the write gets the gate and goes out) and then keeps the earbud's
    /// answer back until the limit has run out. The write has left the gate: the earbud has the frame.
    private func pairWithPairFinInFlightWhenItsLimitRunsOut(
        _ earbud: FakeEarbud) async -> EarbudPairingRelay.PairResult {
        let gate = EarbudSerialGate()
        earbud.gate = gate
        let holdOver = Flag()
        let answerNow = Flag()
        earbud.pairFinAnswer = {
            while !answerNow.isSet { try? await Task.sleep(nanoseconds: 2_000_000) }
        }
        let helpers = Recorder<Task<Void, Never>>()

        let result = await pair(EarbudPairingRelay(gatt: earbud, finTimeout: 0.3)) { _ in
            helpers.append(await self.holdGate(gate, until: holdOver))
            helpers.append(Task {
                try? await Task.sleep(nanoseconds: 50_000_000)
                holdOver.set()
                for _ in 0..<3000 where earbud.pairFinWrites.all.isEmpty { try? await Task.sleep(nanoseconds: 1_000_000) }
                // The limit (0.3 s from the start of the write) has surely run out by now.
                try? await Task.sleep(nanoseconds: 500_000_000)
                answerNow.set()
            })
            return true
        }
        for h in helpers.all { await h.value }
        return result
    }

    /// The limit bounds the wait for the gate, not a write that has already left it. It used to abandon that write
    /// as well: the relay reported `pair_fin_failed:CancellationError()` although the earbud had the PAIR_FIN and
    /// sealed the pairing, so the person was told it failed and started over on a pairing that was already done.
    func testAPairFinThatLeftTheGateBeforeItsLimitRanOutIsNotReportedFailed() async {
        let earbud = makeEarbud()
        let result = await pairWithPairFinInFlightWhenItsLimitRunsOut(earbud)

        XCTAssertEqual(earbud.pairFinWrites.all.count, 1, "the PAIR_FIN reached the earbud")
        guard case .success(let pairId, _) = result else {
            return XCTFail("the earbud got the PAIR_FIN and answered it, but the pairing is reported as \(result)")
        }
        XCTAssertEqual(pairId, expectedPairId)
        XCTAssertFalse(result.needsFreshLink)
    }

    /// The same write, answered with an error after the limit: the report is the write's own error, not the limit's.
    func testAPairFinThatLeftTheGateAndIsRefusedAfterItsLimitReportsTheRefusal() async {
        let earbud = makeEarbud()
        earbud.pairFinAnswerFails = true
        let result = await pairWithPairFinInFlightWhenItsLimitRunsOut(earbud)

        XCTAssertEqual(earbud.pairFinWrites.all.count, 1)
        guard case .defer(let reason, let cached) = result else { return XCTFail("expected defer, got \(result)") }
        XCTAssertTrue(reason.hasPrefix("pair_fin_failed"), reason)
        XCTAssertTrue(reason.contains("boom"), "the failure is the write's own, not the time limit's: \(reason)")
        XCTAssertTrue(cached)
        XCTAssertTrue(result.needsFreshLink)
    }

    // MARK: - needsFreshLink

    func testNeedsFreshLinkPerOutcome() {
        XCTAssertFalse(EarbudPairingRelay.PairResult.success(pairId: Data(count: 32)).needsFreshLink)
        XCTAssertFalse(EarbudPairingRelay.PairResult.defer(reason: "x").needsFreshLink)
        XCTAssertFalse(EarbudPairingRelay.PairResult.defer(reason: "x", pairRespCached: false).needsFreshLink)
        XCTAssertTrue(EarbudPairingRelay.PairResult.defer(reason: "x", pairRespCached: true).needsFreshLink)
        XCTAssertTrue(EarbudPairingRelay.PairResult.sasRejected(pairId: Data(count: 32)).needsFreshLink)
    }

    func testAFailureBeforeThePairRespLeavesTheLinkUsable() async {
        let notConnected = makeEarbud()
        notConnected.isConnected = false
        let r1 = await pair(EarbudPairingRelay(gatt: notConnected)) { _ in true }
        guard case .defer(let reason1, let cached1) = r1 else { return XCTFail("got \(r1)") }
        XCTAssertEqual(reason1, "earbud_not_connected")
        XCTAssertFalse(cached1)

        let beginFails = makeEarbud()
        beginFails.failPairBegin = true
        let r2 = await pair(EarbudPairingRelay(gatt: beginFails)) { _ in true }
        guard case .defer(let reason2, let cached2) = r2 else { return XCTFail("got \(r2)") }
        XCTAssertTrue(reason2.hasPrefix("pair_begin_failed"))
        XCTAssertFalse(cached2, "nothing is cached on the earbud yet: the same link is reused (the stage-2 flow)")
        XCTAssertFalse(r2.needsFreshLink)
    }

    func testAFailureFromThePairRespOnNeedsAFreshLink() async {
        let respFails = makeEarbud()
        respFails.failPairResp = true
        let r1 = await pair(EarbudPairingRelay(gatt: respFails)) { _ in true }
        guard case .defer(let reason1, _) = r1 else { return XCTFail("got \(r1)") }
        XCTAssertTrue(reason1.hasPrefix("pair_resp_error"))
        XCTAssertTrue(r1.needsFreshLink, "the first chunk-index write already made the earbud copy its PAIR_RESP")

        let garbled = FakeEarbud(pairResp: Data(count: 100))
        let r2 = await pair(EarbudPairingRelay(gatt: garbled)) { _ in true }
        guard case .defer(let reason2, _) = r2 else { return XCTFail("got \(r2)") }
        XCTAssertEqual(reason2, "pair_resp_parse_failed")
        XCTAssertTrue(r2.needsFreshLink)

        let finFails = makeEarbud()
        finFails.failPairFin = true
        let r3 = await pair(EarbudPairingRelay(gatt: finFails)) { _ in true }
        guard case .defer(let reason3, _) = r3 else { return XCTFail("got \(r3)") }
        XCTAssertTrue(reason3.hasPrefix("pair_fin_failed"))
        XCTAssertTrue(r3.needsFreshLink)
    }

    // MARK: - API

    func testTheDefaultTimeoutIsTwoMinutes() {
        XCTAssertEqual(EarbudPairingRelay.sasConfirmTimeoutDefault, 120)
    }

    func testTheDefaultPairFinTimeoutIsTenSeconds() {
        XCTAssertEqual(EarbudPairingRelay.finTimeoutDefault, 10)
    }
}
