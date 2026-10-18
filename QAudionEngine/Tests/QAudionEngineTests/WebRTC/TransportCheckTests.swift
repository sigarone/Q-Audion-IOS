import XCTest
@testable import QAudionEngine

/// The verdict of the transport check for each mode, the counting of candidate types, the summary "Segnala problema"
/// copies (no addresses), and the "Confermo" record (mode, verdict and date).
///
/// The gathering itself (`TransportCandidateProbe`) needs a PeerConnection and a network and is not run here; what it
/// is given (the plan) is covered by `TransportPlanTests`, what it returns is turned into a verdict by the rules below.
final class TransportCheckTests: XCTestCase {

    private typealias Mode = TransportSettingsViewModel.Mode

    private func plan(_ mode: Mode, custom: String? = nil, bridge: Bool = false) -> TransportPlan {
        TransportPlan.make(mode: mode, customTurnUrl: custom.flatMap { URL(string: $0) }, bridgeAvailable: bridge)
    }

    /// A custom TURN server with its own user name and password.
    private let customServer = "turn:custom-user:custom-secret@custom.example.test:3478"

    private func counts(host: Int = 0, srflx: Int = 0, relay: Int = 0, other: Int = 0) -> TransportCandidateCounts {
        TransportCandidateCounts(host: host, srflx: srflx, relay: relay, other: other)
    }

    private func outcome(_ mode: Mode, _ c: TransportCandidateCounts, listAvailable: Bool = true) -> TransportCheckOutcome {
        TransportCheckOutcome.evaluate(plan: plan(mode), counts: c, serverListAvailable: listAvailable)
    }

    // MARK: - Candidate lines

    private let hostLine = "candidate:842163049 1 udp 2122260223 192.168.7.21 54321 typ host generation 0 ufrag abCd network-id 1"
    private let srflxLine = "candidate:1 1 udp 1686052607 203.0.113.9 61000 typ srflx raddr 192.168.7.21 rport 61000 generation 0 ufrag abCd network-id 1"
    private let relayLine = "candidate:2 1 udp 41885439 198.51.100.4 49152 typ relay raddr 0.0.0.0 rport 0 generation 0 ufrag abCd network-id 1"

    func test_candidateLinesAreCountedByTheirType() {
        var c = TransportCandidateCounts()
        c.add(candidateSdp: hostLine)
        c.add(candidateSdp: hostLine)
        c.add(candidateSdp: srflxLine)
        c.add(candidateSdp: relayLine)
        c.add(candidateSdp: "candidate:3 1 udp 1 10.0.0.2 1000 typ prflx generation 0")
        c.add(candidateSdp: "candidate:garbage")
        c.add(candidateSdp: "")
        XCTAssertEqual(c.host, 2)
        XCTAssertEqual(c.srflx, 1)
        XCTAssertEqual(c.relay, 1)
        XCTAssertEqual(c.other, 3, "prflx, a line without a type and an empty line")
        XCTAssertEqual(c.total, 7)
    }

    func test_theTypeIsTheWordAfterTyp() {
        XCTAssertEqual(TransportCandidateCounts.candidateType(of: hostLine), "host")
        XCTAssertEqual(TransportCandidateCounts.candidateType(of: relayLine), "relay")
        XCTAssertNil(TransportCandidateCounts.candidateType(of: "candidate:1 1 udp 1 10.0.0.1 9 typ"))
        XCTAssertNil(TransportCandidateCounts.candidateType(of: "candidate:1 1 udp 1 10.0.0.1 9"))
    }

    // MARK: - Verdicts

    func test_p2pIsOkWithCandidatesAndNoRelayAndFailsOnAnyRelay() {
        XCTAssertEqual(outcome(.p2p, counts(host: 2, srflx: 1)), .ok)
        XCTAssertEqual(outcome(.p2p, counts(host: 2)), .ok)
        XCTAssertEqual(outcome(.p2p, counts(host: 2, relay: 1)), .unexpectedRelay)
        XCTAssertEqual(outcome(.p2p, counts(relay: 3)), .unexpectedRelay)
    }

    func test_p2pWithNoCandidateAtAllIsNotOkBecauseNothingWasTested() {
        XCTAssertEqual(outcome(.p2p, counts()), .noCandidates)
    }

    func test_turnAndRelayNeedAtLeastOneRelayCandidate() {
        for mode in [Mode.turn, .relay] {
            XCTAssertEqual(outcome(mode, counts(relay: 1)), .ok, "\(mode)")
            XCTAssertEqual(outcome(mode, counts(host: 2, srflx: 1, relay: 2)), .ok, "\(mode)")
            XCTAssertEqual(outcome(mode, counts()), .noRelayCandidate, "\(mode)")
            XCTAssertEqual(outcome(mode, counts(host: 2, srflx: 1)), .noRelayCandidate, "\(mode): direct candidates do not count")
        }
    }

    func test_turnAndRelayReportAMissingServerListInsteadOfAMissingCandidate() {
        for mode in [Mode.turn, .relay] {
            XCTAssertEqual(outcome(mode, counts(), listAvailable: false), .serverListUnavailable, "\(mode)")
            XCTAssertEqual(outcome(mode, counts(), listAvailable: true), .noRelayCandidate, "\(mode)")
        }
    }

    func test_autoIsOkWithAnyCandidate() {
        XCTAssertEqual(outcome(.auto, counts(host: 1)), .ok)
        XCTAssertEqual(outcome(.auto, counts(relay: 1)), .ok)
        XCTAssertEqual(outcome(.auto, counts()), .noCandidates)
    }

    /// Host candidates need no server, so a gathering with no server at all still produces them. Auto and p2p used to read
    /// that as OK: the check had tried nothing and said everything was fine. In every mode, no server tried is not OK, and
    /// it does not matter what the gathering found.
    func test_aCheckThatTriedNoServerIsNotOkInAnyModeWhateverItFound() {
        let found = [counts(), counts(host: 3), counts(host: 3, srflx: 1), counts(host: 2, relay: 1), counts(relay: 2)]
        for mode in Mode.allCases {
            for c in found {
                let verdict = outcome(mode, c, listAvailable: false)
                XCTAssertEqual(verdict, .serverListUnavailable, "\(mode) \(c)")
                XCTAssertFalse(verdict.isOk, "\(mode) \(c)")
            }
        }
        // The same findings with a server to try give the usual verdicts.
        XCTAssertEqual(outcome(.p2p, counts(host: 3, srflx: 1)), .ok)
        XCTAssertEqual(outcome(.auto, counts(host: 3)), .ok)
        XCTAssertEqual(outcome(.p2p, counts(host: 2, relay: 1)), .unexpectedRelay)
    }

    /// The check says "a server was tried" when the list the plan hands to libwebrtc is not empty
    /// (`TransportCandidateProbe`: `serverListAvailable = !plannedServers.isEmpty`). That list is empty when the server
    /// gave nothing, or nothing the mode may use, and never for a custom server, which brings its own.
    func test_theListTheCheckTriesIsEmptyWhenThereIsNothingTheModeMayUse() {
        let stunOnly = [RelayServer(urls: ["stun:stun.example.test:3478"])]
        let turnOnly = [RelayServer(urls: ["turn:turn.example.test:3478"], username: "u", credential: "p")]
        for mode in Mode.allCases {
            XCTAssertTrue(plan(mode).servers(pool: [], bridgeIceUrl: nil).isEmpty, "\(mode): no list from the server")
        }
        XCTAssertFalse(plan(.auto).servers(pool: stunOnly, bridgeIceUrl: nil).isEmpty)
        XCTAssertFalse(plan(.p2p).servers(pool: stunOnly, bridgeIceUrl: nil).isEmpty)
        XCTAssertTrue(plan(.p2p).servers(pool: turnOnly, bridgeIceUrl: nil).isEmpty, "p2p keeps STUN servers only")
        XCTAssertTrue(plan(.turn).servers(pool: stunOnly, bridgeIceUrl: nil).isEmpty, "turn keeps TURN servers only")
        XCTAssertFalse(plan(.turn).servers(pool: turnOnly, bridgeIceUrl: nil).isEmpty)
        XCTAssertFalse(plan(.relay, bridge: true).servers(pool: turnOnly, bridgeIceUrl: "turn:127.0.0.1:50123?transport=udp").isEmpty,
                       "the bridge is listed with the credentials of the pool")
        XCTAssertTrue(plan(.relay, bridge: true).servers(pool: [], bridgeIceUrl: "turn:127.0.0.1:50123?transport=udp").isEmpty,
                      "a bridge needs the credentials of the pool: with no list there is nothing to try")
        XCTAssertTrue(plan(.relay, bridge: false).servers(pool: stunOnly, bridgeIceUrl: nil).isEmpty,
                      "relay without the bridge falls back to TURN servers of the pool: none here")
        for mode in [Mode.auto, .turn, .relay] {
            XCTAssertFalse(plan(mode, custom: customServer).servers(pool: [], bridgeIceUrl: nil).isEmpty,
                           "\(mode): a custom server needs no list")
        }
    }

    func test_onlyOkIsOk() {
        XCTAssertTrue(TransportCheckOutcome.ok.isOk)
        for other in [TransportCheckOutcome.unexpectedRelay, .noRelayCandidate, .noCandidates, .serverListUnavailable] {
            XCTAssertFalse(other.isOk, "\(other)")
        }
    }

    // MARK: - The summary

    func test_theSummaryHasModeRouteCandidateTypesAndOutcomeAndNothingElse() {
        let result = TransportCheckResult(
            plan: plan(.relay, bridge: true),
            counts: counts(relay: 2),
            serverListAvailable: true,
            gatheringTimedOut: false)
        let expected = [
            "transport_check",
            "mode=relay",
            "route=wssBridge",
            "custom_server=none",
            "candidates host=0 srflx=0 relay=2 other=0",
            "gathering=complete",
            "result=ok"
        ].joined(separator: "\n")
        XCTAssertEqual(result.summary, expected)
    }

    func test_theSummaryTellsTheFallbackAndTheTimeout() {
        let result = TransportCheckResult(
            plan: plan(.relay, bridge: false),
            counts: counts(),
            serverListAvailable: true,
            gatheringTimedOut: true)
        XCTAssertTrue(result.summary.contains("route=poolTurnFallback"))
        XCTAssertTrue(result.summary.contains("gathering=timeout"))
        XCTAssertTrue(result.summary.contains("result=noRelayCandidate"))
    }

    func test_theSummaryNeverCarriesAnAddressAPortOrTheCustomServer() {
        // Counts are fed from real-looking lines, with addresses and ports in them.
        var c = TransportCandidateCounts()
        for line in [hostLine, srflxLine, relayLine] { c.add(candidateSdp: line) }
        let custom = "turn:secret-user:secret-pass@custom-host.example.test:3478"
        let results = [
            TransportCheckResult(plan: plan(.auto), counts: c, serverListAvailable: true, gatheringTimedOut: false),
            TransportCheckResult(plan: plan(.relay, custom: custom), counts: c, serverListAvailable: true, gatheringTimedOut: false),
            TransportCheckResult(plan: plan(.p2p, custom: custom), counts: c, serverListAvailable: true, gatheringTimedOut: false)
        ]
        for result in results {
            let summary = result.summary
            for forbidden in ["192.168.7.21", "203.0.113.9", "198.51.100.4", "54321", "61000", "49152",
                              "secret-user", "secret-pass", "custom-host", "example.test", "3478", "@"] {
                XCTAssertFalse(summary.contains(forbidden), "the summary leaks \(forbidden):\n\(summary)")
            }
            // No dotted-quad and no host:port shape either.
            XCTAssertNil(summary.range(of: #"\d+\.\d+\.\d+\.\d+"#, options: .regularExpression), summary)
            XCTAssertNil(summary.range(of: #":\d{2,5}"#, options: .regularExpression), summary)
        }
        XCTAssertTrue(results[1].summary.contains("custom_server=used"))
        XCTAssertTrue(results[2].summary.contains("custom_server=ignored"), "p2p ignores a TURN address and says so")
    }

    // MARK: - "Confermo"

    private func freshDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "test.transportcheck.\(name).\(UUID().uuidString)"
        // The suite name is a fresh, well-formed, non-empty string: UserDefaults(suiteName:) never returns nil for it.
        // swiftlint:disable:next force_unwrapping
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func test_aConfirmationKeepsTheModeTheOutcomeAndTheDate() {
        let store = TransportCheckConfirmationStore(defaults: freshDefaults())
        XCTAssertNil(store.load(), "nothing confirmed yet")
        let when = Date(timeIntervalSince1970: 1_790_000_000)
        store.record(mode: .relay, outcome: .ok, at: when)
        let loaded = store.load()
        XCTAssertEqual(loaded?.mode, .relay)
        XCTAssertEqual(loaded?.outcome, .ok)
        XCTAssertEqual(loaded?.date.timeIntervalSince1970 ?? 0, 1_790_000_000, accuracy: 0.001)
    }

    /// "Confermo" is available after a check that was NOT OK too, and the record says which verdict it confirmed: every
    /// outcome survives the round trip through the storage, so the line "Ultima conferma" can tell OK from NON OK.
    func test_aConfirmationOfACheckThatWasNotOkKeepsThatOutcome() {
        for outcome in TransportCheckOutcome.allCases {
            let store = TransportCheckConfirmationStore(defaults: freshDefaults())
            store.record(mode: .turn, outcome: outcome, at: Date(timeIntervalSince1970: 1_790_000_000))
            XCTAssertEqual(store.load()?.outcome, outcome, "\(outcome)")
            XCTAssertEqual(store.load()?.outcome.isOk, outcome == .ok, "\(outcome)")
            XCTAssertEqual(store.load()?.mode, .turn, "\(outcome)")
        }
    }

    /// "Confermo" on a result: the store takes the mode of the plan and the verdict of the result, so a check that was
    /// NOT OK is recorded as NOT OK (the screen used to record only the mode, and the line read like an approval).
    func test_confirmingAResultRecordsItsModeAndItsVerdictOkOrNot() {
        let ok = TransportCheckResult(plan: plan(.relay, bridge: true), counts: counts(relay: 2),
                                      serverListAvailable: true, gatheringTimedOut: false)
        let notOk = TransportCheckResult(plan: plan(.turn), counts: counts(host: 3),
                                         serverListAvailable: true, gatheringTimedOut: false)
        XCTAssertEqual(ok.outcome, .ok)
        XCTAssertEqual(notOk.outcome, .noRelayCandidate)

        let store = TransportCheckConfirmationStore(defaults: freshDefaults())
        store.record(result: notOk, at: Date(timeIntervalSince1970: 1_790_000_000))
        XCTAssertEqual(store.load()?.mode, .turn)
        XCTAssertEqual(store.load()?.outcome, .noRelayCandidate)
        XCTAssertEqual(store.load()?.outcome.isOk, false)

        store.record(result: ok, at: Date(timeIntervalSince1970: 1_790_000_500))
        XCTAssertEqual(store.load()?.mode, .relay)
        XCTAssertEqual(store.load()?.outcome, .ok)
        XCTAssertEqual(store.load()?.date.timeIntervalSince1970 ?? 0, 1_790_000_500, accuracy: 0.001)
    }

    func test_theLastConfirmationReplacesTheOneBefore() {
        let store = TransportCheckConfirmationStore(defaults: freshDefaults())
        store.record(mode: .p2p, outcome: .ok, at: Date(timeIntervalSince1970: 1_790_000_000))
        store.record(mode: .turn, outcome: .noRelayCandidate, at: Date(timeIntervalSince1970: 1_790_000_500))
        XCTAssertEqual(store.load()?.mode, .turn)
        XCTAssertEqual(store.load()?.outcome, .noRelayCandidate, "the outcome of the first confirmation is gone")
        XCTAssertEqual(store.load()?.date.timeIntervalSince1970 ?? 0, 1_790_000_500, accuracy: 0.001)
        store.clear()
        XCTAssertNil(store.load())
    }

    func test_aStoredConfirmationThatCannotBeReadIsNoConfirmation() {
        let defaults = freshDefaults()
        defaults.set("not-a-mode", forKey: TransportCheckConfirmationStore.keyMode)
        defaults.set("ok", forKey: TransportCheckConfirmationStore.keyOutcome)
        defaults.set(1_790_000_000.0, forKey: TransportCheckConfirmationStore.keyDate)
        XCTAssertNil(TransportCheckConfirmationStore(defaults: defaults).load())

        let noDate = freshDefaults()
        noDate.set("relay", forKey: TransportCheckConfirmationStore.keyMode)
        noDate.set("ok", forKey: TransportCheckConfirmationStore.keyOutcome)
        XCTAssertNil(TransportCheckConfirmationStore(defaults: noDate).load())

        let noOutcome = freshDefaults()
        noOutcome.set("relay", forKey: TransportCheckConfirmationStore.keyMode)
        noOutcome.set(1_790_000_000.0, forKey: TransportCheckConfirmationStore.keyDate)
        XCTAssertNil(TransportCheckConfirmationStore(defaults: noOutcome).load(), "a confirmation without a verdict is not shown")

        let unknownOutcome = freshDefaults()
        unknownOutcome.set("relay", forKey: TransportCheckConfirmationStore.keyMode)
        unknownOutcome.set("fine", forKey: TransportCheckConfirmationStore.keyOutcome)
        unknownOutcome.set(1_790_000_000.0, forKey: TransportCheckConfirmationStore.keyDate)
        XCTAssertNil(TransportCheckConfirmationStore(defaults: unknownOutcome).load())
    }
}
