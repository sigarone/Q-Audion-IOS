import XCTest
@testable import QAudionEngine

/// The rule that a message is never stranded on the Bluetooth mesh: when it goes to the network path, and why.
final class MeshFallbackPolicyTests: XCTestCase {

    private let t0: Int64 = 1_800_000_000_000
    private let fallbackMs = MeshFallbackPolicy.fallbackMs

    private func reason(
        age: Int64, network: Bool = true, radioOff: Bool = false, trigger: MeshFallbackPolicy.Trigger = .timer
    ) -> MeshFallbackReason? {
        MeshFallbackPolicy.reason(
            createdAtMs: t0, nowMs: t0 + age, networkUsable: network, radioOff: radioOff, trigger: trigger)
    }

    // MARK: - Deadline (fake clock)

    func testDeadlineIs120Seconds() {
        XCTAssertEqual(fallbackMs, 120_000)
    }

    func testBeforeTheDeadlineTheMessageStaysOnTheMesh() {
        XCTAssertNil(reason(age: 0))
        XCTAssertNil(reason(age: fallbackMs - 1))
    }

    func testAtTheDeadlineWithNetworkItGoesToTheServer() {
        XCTAssertEqual(reason(age: fallbackMs), .deadline)
        XCTAssertEqual(reason(age: fallbackMs + 30_000), .deadline)
    }

    func testPastTheDeadlineWithoutNetworkItWaits() {
        XCTAssertNil(reason(age: fallbackMs + 1, network: false))
        XCTAssertNil(reason(age: 30 * 60 * 1000, network: false))
    }

    // MARK: - Radio off

    func testRadioOffHandsOverAtOnceWhateverTheAge() {
        XCTAssertEqual(reason(age: 0, radioOff: true), .radioOff)
        XCTAssertEqual(reason(age: 0, network: false, radioOff: true), .radioOff)
    }

    // MARK: - Give-up never fails the message

    func testGiveUpWithNetworkGoesToTheServer() {
        XCTAssertEqual(reason(age: MeshOutboxPolicy.giveUpMs + 1), .giveup)
    }

    func testGiveUpWithoutNetworkStillHandsOverToTheNetworkOutbox() {
        XCTAssertEqual(reason(age: MeshOutboxPolicy.giveUpMs + 1, network: false), .giveup)
    }

    // MARK: - Reconnect

    func testReconnectHandsOverRowsPastTheDeadline() {
        XCTAssertEqual(reason(age: fallbackMs, trigger: .reconnect), .reconnect)
        XCTAssertNil(reason(age: fallbackMs - 1, trigger: .reconnect))
    }

    func testQueueHandsOverOnlyMessagesPastTheDeadlineOnReconnect() {
        func entry(_ id: String, kind: MeshOutboxEntry.Kind, age: Int64) -> MeshOutboxEntry {
            MeshOutboxEntry(
                id: id, kind: kind, messageId: id, conversationId: "c", peerUserId: "p",
                targetNodeHex: "aabbcc", payloadB64: "", createdAtMs: t0 - age)
        }
        let queue = MeshOutboxQueue(entries: [
            entry("old", kind: .message, age: fallbackMs + 5_000),
            entry("fresh", kind: .message, age: 10_000),
            entry("receipt", kind: .receipt, age: fallbackMs * 10),
            entry("older", kind: .message, age: fallbackMs * 3),
        ])
        let out = queue.fallbackCandidates(nowMs: t0, networkUsable: true, radioOff: false, trigger: .reconnect)
        XCTAssertEqual(out.map { $0.entry.id }, ["older", "old"])
        XCTAssertEqual(out.map { $0.reason }, [.reconnect, .reconnect])
    }

    func testQueueGiveUpWithNetworkIsAHandOverNeverAFailure() {
        let stale = MeshOutboxEntry(
            id: "m", kind: .message, messageId: "m", conversationId: "c", peerUserId: "p",
            targetNodeHex: "aabbcc", payloadB64: "", createdAtMs: t0 - MeshOutboxPolicy.giveUpMs - 1)
        let out = MeshOutboxQueue(entries: [stale])
            .fallbackCandidates(nowMs: t0, networkUsable: true, radioOff: false, trigger: .timer)
        XCTAssertEqual(out.map { $0.reason }, [.giveup])
    }

    // MARK: - Vocabulary and the user-facing note

    func testReasonTokensAreTheClosedLogVocabulary() {
        XCTAssertEqual(Set(MeshFallbackReason.allCases.map(\.rawValue)), ["deadline", "radio_off", "giveup", "reconnect", "user_choice"])
        for reason in MeshFallbackReason.allCases {
            XCTAssertEqual(MeshLog.line(.fallback, [("ph", "ba7816bf"), ("reason", reason.rawValue)]),
                           "fallback ph=ba7816bf reason=\(reason.rawValue)")
        }
    }

    func testOnlyAConstraintIsBluetoothOnly() {
        XCTAssertFalse(MeshFallbackPolicy.isBluetoothOnly(preference: .preferMesh, armedMeshTarget: false))
        XCTAssertFalse(MeshFallbackPolicy.isBluetoothOnly(preference: .networkOnly, armedMeshTarget: false))
        XCTAssertTrue(MeshFallbackPolicy.isBluetoothOnly(preference: .meshOnly, armedMeshTarget: false))
        XCTAssertTrue(MeshFallbackPolicy.isBluetoothOnly(preference: .preferMesh, armedMeshTarget: true))
    }

    func testAnEntryStoredByAnEarlierBuildStillDecodes() throws {
        let json = "{\"id\":\"m\",\"kind\":\"message\",\"messageId\":\"m\",\"conversationId\":\"c\",\"peerUserId\":\"p\",\"targetNodeHex\":\"aabbcc\",\"payloadB64\":\"\",\"createdAtMs\":1,\"attempts\":0,\"firstHopAccepted\":false}"
        let entry = try JSONDecoder().decode(MeshOutboxEntry.self, from: Data(json.utf8))
        XCTAssertNotEqual(entry.bluetoothOnly, true)
    }
}

/// "Reachable now" is read from the live links: once every link is down, a send goes to the network.
final class MeshLiveReachTests: XCTestCase {

    private func decide(_ preference: MeshRoutingPreference, links: [MeshLiveLink], target: String = "aaaaaa") -> MeshRoutingDecision {
        meshRoutingDecision(
            preference: preference, armedMeshTarget: false,
            peerReachableOverMesh: MeshLiveReach.reach(toNodeHex: target, liveLinks: links).reachable)
    }

    func testLinksUpThenAllDownSendsOverTheNetwork() {
        var links = [MeshLiveLink(nodeHex: "aaaaaa"), MeshLiveLink(nodeHex: "bbbbbb"), MeshLiveLink(nodeHex: "cccccc"), MeshLiveLink(nodeHex: "dddddd")]
        XCTAssertEqual(decide(.preferMesh, links: links), .sendOverMesh)
        links.removeAll()
        XCTAssertEqual(decide(.preferMesh, links: links), .sendOverNetwork)
    }

    func testABridgeCountsOnlyWhileItsOwnLinkIsLive() {
        let bridge = MeshLiveLink(nodeHex: "bbbbbb", announcedNeighborHexes: ["aaaaaa"])
        let up = MeshLiveReach.reach(toNodeHex: "aaaaaa", liveLinks: [bridge])
        XCTAssertTrue(up.reachable)
        XCTAssertEqual(up.viaBridgeNodeHex, "bbbbbb")
        XCTAssertFalse(MeshLiveReach.reach(toNodeHex: "aaaaaa", liveLinks: []).reachable)
    }

    func testADirectLinkWinsOverABridge() {
        let links = [MeshLiveLink(nodeHex: "bbbbbb", announcedNeighborHexes: ["aaaaaa"]), MeshLiveLink(nodeHex: "aaaaaa")]
        let r = MeshLiveReach.reach(toNodeHex: "aaaaaa", liveLinks: links)
        XCTAssertTrue(r.reachable)
        XCTAssertNil(r.viaBridgeNodeHex)
    }

    func testOtherNodesLinksDoNotMakeTheTargetReachable() {
        XCTAssertFalse(MeshLiveReach.reach(toNodeHex: "aaaaaa", liveLinks: [MeshLiveLink(nodeHex: "bbbbbb")]).reachable)
    }

    func testBluetoothFirstStillQueuesWhenNothingIsReachable() {
        XCTAssertEqual(decide(.meshOnly, links: []), .queueForMesh)
        XCTAssertEqual(decide(.networkOnly, links: [MeshLiveLink(nodeHex: "aaaaaa")]), .sendOverNetwork)
    }
}

/// "Solo BT" (Bluetooth only) never reaches the network without the user's answer, on every path.
final class MeshBluetoothOnlyTests: XCTestCase {

    private let t0: Int64 = 1_800_000_000_000
    private let fallbackMs = MeshFallbackPolicy.fallbackMs

    private func entry(_ id: String, bluetoothOnly: Bool, age: Int64) -> MeshOutboxEntry {
        MeshOutboxEntry(
            id: id, kind: .message, messageId: id, conversationId: "c", peerUserId: "p",
            targetNodeHex: "aabbcc", payloadB64: "", createdAtMs: t0 - age, bluetoothOnly: bluetoothOnly)
    }

    func testBluetoothOnlyIsNeverAnAutomaticHandOverOnAnyPath() {
        let ages: [Int64] = [0, fallbackMs - 1, fallbackMs, fallbackMs * 5, MeshOutboxPolicy.giveUpMs + 1, MeshOutboxPolicy.giveUpMs * 3]
        for age in ages {
            for network in [true, false] {
                for radioOff in [true, false] {
                    for trigger in [MeshFallbackPolicy.Trigger.timer, .reconnect] {
                        let queue = MeshOutboxQueue(entries: [entry("solo", bluetoothOnly: true, age: age)])
                        let out = queue.fallbackCandidates(nowMs: t0, networkUsable: network, radioOff: radioOff, trigger: trigger)
                        XCTAssertTrue(out.isEmpty, "age=\(age) network=\(network) radioOff=\(radioOff) trigger=\(trigger)")
                    }
                }
            }
        }
    }

    func testPreferBluetoothStillFallsBackSilently() {
        let queue = MeshOutboxQueue(entries: [entry("pref", bluetoothOnly: false, age: fallbackMs)])
        XCTAssertEqual(queue.fallbackCandidates(nowMs: t0, networkUsable: true, radioOff: false).map { $0.reason }, [.deadline])
    }

    func testRetryNeverForcesTheNetworkForBluetoothOnly() {
        XCTAssertFalse(MeshFallbackPolicy.retryForcesNetwork(preference: .meshOnly, armedMeshTarget: false))
        XCTAssertFalse(MeshFallbackPolicy.retryForcesNetwork(preference: .preferMesh, armedMeshTarget: true))
        XCTAssertTrue(MeshFallbackPolicy.retryForcesNetwork(preference: .preferMesh, armedMeshTarget: false))
        XCTAssertTrue(MeshFallbackPolicy.retryForcesNetwork(preference: .networkOnly, armedMeshTarget: false))
    }

    // MARK: - The prompt and the persistent state

    private func action(
        age: Int64, network: Bool = true, radioOff: Bool = false, state: MeshBtOnlyState = .idle
    ) -> MeshBtOnlyAction {
        MeshFallbackPolicy.bluetoothOnlyAction(
            createdAtMs: t0, nowMs: t0 + age, networkUsable: network, radioOff: radioOff, state: state)
    }

    func testPromptAtTheDeadlineWhenTheNetworkIsUsable() {
        XCTAssertEqual(action(age: fallbackMs - 1), .none)
        XCTAssertEqual(action(age: fallbackMs), .prompt)
        XCTAssertEqual(action(age: fallbackMs, network: false), .none)
    }

    func testPromptAtOnceWhenTheRadioIsOff() {
        XCTAssertEqual(action(age: 0, radioOff: true), .prompt)
        XCTAssertEqual(action(age: 0, network: false, radioOff: true), .prompt)
    }

    func testRefusedAndPromptedMessagesAreNotPromptedAgainBeforeTheGiveUp() {
        for state in [MeshBtOnlyState.prompted, .declined] {
            XCTAssertEqual(action(age: fallbackMs * 10, state: state), MeshBtOnlyAction.none)
            XCTAssertEqual(action(age: 0, radioOff: true, state: state), MeshBtOnlyAction.none)
        }
    }

    func testTheGiveUpParksTheMessageWhateverItsState() {
        for state in [MeshBtOnlyState.idle, .prompted, .declined] {
            XCTAssertEqual(action(age: MeshOutboxPolicy.giveUpMs + 1, state: state), .park)
        }
        // Already parked: nothing more to do, and it is never failed or sent.
        XCTAssertEqual(action(age: MeshOutboxPolicy.giveUpMs + 1, state: .undelivered), MeshBtOnlyAction.none)
    }

    func testReconnectChangesNothingForBluetoothOnlyExceptAPromptThatWasDue() {
        // A reconnect makes the network usable, so a prompt that was waiting for it is due; it is never a hand-over.
        let queue = MeshOutboxQueue(entries: [entry("solo", bluetoothOnly: true, age: fallbackMs + 1)])
        let out = queue.bluetoothOnlyActions(nowMs: t0, networkUsable: true, radioOff: false, stateOf: { _ in .idle })
        XCTAssertEqual(out.map { $0.action }, [.prompt])
        XCTAssertTrue(queue.fallbackCandidates(nowMs: t0, networkUsable: true, radioOff: false, trigger: .reconnect).isEmpty)
    }

    func testStatesAreStoredAsPlainTokens() {
        XCTAssertEqual(MeshBtOnlyState.allCases.map(\.rawValue), ["idle", "prompted", "declined", "undelivered"])
    }

    // MARK: - Cold launch

    func testColdLaunchBeforeTheAntennaModeIsRestoredIsNotRadioOff() {
        // ws-authenticated arrives, the stored antenna mode is not applied yet: not off.
        XCTAssertFalse(MeshFallbackPolicy.radioIsOff(featureEnabled: true, modeRequested: false, decisionSettled: false))
        // Once settled with no mode, the antenna really is off.
        XCTAssertTrue(MeshFallbackPolicy.radioIsOff(featureEnabled: true, modeRequested: false, decisionSettled: true))
        XCTAssertFalse(MeshFallbackPolicy.radioIsOff(featureEnabled: true, modeRequested: true, decisionSettled: true))
        // A kill switch is final even before the restore.
        XCTAssertTrue(MeshFallbackPolicy.radioIsOff(featureEnabled: false, modeRequested: false, decisionSettled: false))
    }

    func testColdLaunchNeitherHandsOverNorPromptsForRadioOff() {
        let radioOff = MeshFallbackPolicy.radioIsOff(featureEnabled: true, modeRequested: false, decisionSettled: false)
        let queue = MeshOutboxQueue(entries: [entry("pref", bluetoothOnly: false, age: 5_000), entry("solo", bluetoothOnly: true, age: 5_000)])
        XCTAssertTrue(queue.fallbackCandidates(nowMs: t0, networkUsable: true, radioOff: radioOff, trigger: .reconnect).isEmpty)
        XCTAssertTrue(queue.bluetoothOnlyActions(nowMs: t0, networkUsable: true, radioOff: radioOff, stateOf: { _ in .idle }).isEmpty)
    }
}

/// The prompt table is UI state only: eviction can drop a "no" but never a state the user must see.
final class MeshBtPromptTableTests: XCTestCase {

    func testAtTheCapOnlyDeclinedEntriesAreEvictedOldestFirst() {
        var table = MeshBtPromptTable()
        table.set(.prompted, id: "p", nowMs: 1, maxEntries: 3)
        table.set(.undelivered, id: "u", nowMs: 2, maxEntries: 3)
        table.set(.declined, id: "d-old", nowMs: 3, maxEntries: 3)
        table.set(.declined, id: "d-new", nowMs: 4, maxEntries: 3)
        XCTAssertEqual(table.state(of: "d-old"), .idle)
        XCTAssertEqual(table.state(of: "d-new"), .declined)
        XCTAssertEqual(table.state(of: "p"), .prompted)
        XCTAssertEqual(table.state(of: "u"), .undelivered)
    }

    func testPromptedAndUndeliveredAreNeverEvictedEvenOverTheCap() {
        var table = MeshBtPromptTable()
        for i in 0..<10 {
            table.set(i % 2 == 0 ? .prompted : .undelivered, id: "m\(i)", nowMs: Int64(i), maxEntries: 3)
        }
        XCTAssertEqual(table.items.count, 10)
    }

    func testEvictionNeverReleasesAHeldMessage() {
        // The hold is on the stored row, so the table has no say: a message whose table entry is gone is still held, still
        // outside the automatic hand-over, and asked about again.
        var table = MeshBtPromptTable()
        table.set(.declined, id: "m", nowMs: 1, maxEntries: 1)
        table.set(.declined, id: "other", nowMs: 2, maxEntries: 1)
        XCTAssertEqual(table.state(of: "m"), .idle)
        let entry = MeshOutboxEntry(
            id: "m", kind: .message, messageId: "m", conversationId: "c", peerUserId: "p", targetNodeHex: "aabbcc",
            payloadB64: "", createdAtMs: 0, bluetoothOnly: true)
        let queue = MeshOutboxQueue(entries: [entry])
        XCTAssertTrue(queue.fallbackCandidates(nowMs: MeshFallbackPolicy.fallbackMs * 5, networkUsable: true, radioOff: false).isEmpty)
        XCTAssertEqual(
            queue.bluetoothOnlyActions(nowMs: MeshFallbackPolicy.fallbackMs, networkUsable: true, radioOff: false, stateOf: { table.state(of: $0) }).map { $0.action },
            [.prompt])
    }

    func testIdleRemovesAndRoundTrips() throws {
        var table = MeshBtPromptTable()
        table.set(.prompted, id: "a", nowMs: 5)
        let copy = try JSONDecoder().decode(MeshBtPromptTable.self, from: JSONEncoder().encode(table))
        XCTAssertEqual(copy.state(of: "a"), .prompted)
        table.set(.idle, id: "a", nowMs: 6)
        XCTAssertEqual(table.state(of: "a"), .idle)
    }
}

/// An entry stored by an earlier build has no Bluetooth-only value: it is never handed over on its own.
final class MeshLegacyEntryTests: XCTestCase {

    private func legacy() throws -> MeshOutboxEntry {
        let json = "{\"id\":\"m\",\"kind\":\"message\",\"messageId\":\"m\",\"conversationId\":\"c\",\"peerUserId\":\"p\",\"targetNodeHex\":\"aabbcc\",\"payloadB64\":\"\",\"createdAtMs\":0,\"attempts\":0,\"firstHopAccepted\":false}"
        return try JSONDecoder().decode(MeshOutboxEntry.self, from: Data(json.utf8))
    }

    func testALegacyEntryIsHeldAndPromptedNeverHandedOver() throws {
        let entry = try legacy()
        XCTAssertNil(entry.bluetoothOnly)
        let queue = MeshOutboxQueue(entries: [entry])
        for age in [MeshFallbackPolicy.fallbackMs, MeshOutboxPolicy.giveUpMs + 1] {
            XCTAssertTrue(queue.fallbackCandidates(nowMs: age, networkUsable: true, radioOff: true, trigger: .reconnect).isEmpty)
        }
        let actions = queue.bluetoothOnlyActions(nowMs: MeshFallbackPolicy.fallbackMs, networkUsable: true, radioOff: false, stateOf: { _ in .idle })
        XCTAssertEqual(actions.map { $0.action }, [.prompt])
    }

    func testOnceWorkedOutAnOrdinaryEntryFallsBackAgain() throws {
        var queue = MeshOutboxQueue(entries: [try legacy()])
        queue.setBluetoothOnly(id: "m", false)
        XCTAssertEqual(queue.fallbackCandidates(nowMs: MeshFallbackPolicy.fallbackMs, networkUsable: true, radioOff: false).map { $0.reason }, [.deadline])
        queue.setBluetoothOnly(id: "m", true)
        XCTAssertTrue(queue.fallbackCandidates(nowMs: MeshFallbackPolicy.fallbackMs, networkUsable: true, radioOff: false).isEmpty)
    }
}

final class MeshKeepPlanTests: XCTestCase {
    func testRiprovaWithoutAnEntryReRoutesAndNeverUsesTheNetwork() {
        XCTAssertEqual(MeshFallbackPolicy.keepPlan(hasEntry: false, routeAvailable: true), .reroute)
        XCTAssertEqual(MeshFallbackPolicy.keepPlan(hasEntry: false, routeAvailable: false), .stayHeld)
        XCTAssertEqual(MeshFallbackPolicy.keepPlan(hasEntry: true, routeAvailable: false), .keepEntry)
        XCTAssertEqual(MeshFallbackPolicy.keepPlan(hasEntry: true, routeAvailable: true), .keepEntry)
    }
}

/// In a Bluetooth-only chat the mesh cannot carry anything but text: other content is held at once.
final class MeshContentHoldTests: XCTestCase {

    func testAnAttachmentAndAVoiceNoteAreHeldInABluetoothOnlyChat() {
        for raw in ["file", "voice"] {
            let kind = MeshFallbackPolicy.ContentKind.ofFileKind(raw)
            XCTAssertNotEqual(kind, .text)
            XCTAssertTrue(MeshFallbackPolicy.holdsContent(kind: kind, preference: .meshOnly, armedMeshTarget: false), raw)
            XCTAssertTrue(MeshFallbackPolicy.holdsContent(kind: kind, preference: .preferMesh, armedMeshTarget: true), raw)
        }
    }

    func testOtherChatsAreNotHeld() {
        for kind in MeshFallbackPolicy.ContentKind.allCases {
            XCTAssertFalse(MeshFallbackPolicy.holdsContent(kind: kind, preference: .preferMesh, armedMeshTarget: false))
            XCTAssertFalse(MeshFallbackPolicy.holdsContent(kind: kind, preference: .networkOnly, armedMeshTarget: false))
        }
    }

    func testEveryKindButTextIsHeldAndLiveLocationToo() {
        XCTAssertFalse(MeshFallbackPolicy.holdsContent(kind: .text, preference: .meshOnly, armedMeshTarget: false))
        for kind in MeshFallbackPolicy.ContentKind.allCases where kind != .text {
            XCTAssertTrue(MeshFallbackPolicy.holdsContent(kind: kind, preference: .meshOnly, armedMeshTarget: false))
        }
        XCTAssertEqual(MeshFallbackPolicy.ContentKind.ofFileKind("image"), .image)
        XCTAssertEqual(MeshFallbackPolicy.ContentKind.ofFileKind("video"), .video)
    }
}
