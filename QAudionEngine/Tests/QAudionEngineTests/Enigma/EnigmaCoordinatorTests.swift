import XCTest
@testable import QAudionEngine

/// The hand-off between the two hooks and the screen: which packet belongs to which row, the hold-back of a received row (at
/// most 500 ms, whatever happens), the stall counter, the bus (first-line exit with the effect off), and the policy of the hooks.
final class EnigmaCoordinatorTests: XCTestCase {

    private final class Clock {
        var now: Int64 = 10_000
    }

    private let ms: Int64 = 1_000_000

    private struct Rig {
        let coordinator: EnigmaCoordinator
        let effect: EnigmaEffect
        let clock: Clock
    }

    private func makeRig(level: EnigmaLevel = .full, flagOn: Bool = true, conversation: String? = "conv-1") -> Rig {
        let clock = Clock()
        let effect = EnigmaEffect(environment: { EnigmaEnvironment() }, seedSource: { 1 })
        effect.configure(flagOn: flagOn, userLevel: level)
        let coordinator = EnigmaCoordinator(effect: effect, clock: { clock.now })
        coordinator.conversationKey = conversation
        return Rig(coordinator: coordinator, effect: effect, clock: clock)
    }

    private func event(
        _ id: String, _ dir: EnigmaDirection, conversation: String = "conv-1", bytes: Int = 90
    ) -> EnigmaWireEvent {
        let wire = Data((0..<min(bytes, EnigmaBus.prefixBytes)).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        return EnigmaWireEvent(
            rowId: id, conversationKey: conversation, direction: dir, packetBytes: bytes,
            wirePrefixBase64: wire.base64EncodedString())
    }

    private func textRow(_ id: String, outgoing: Bool, _ text: String = "ciao mondo") -> EnigmaRow {
        EnigmaRow(id: id, isOutgoing: outgoing, kind: .text, text: text)
    }

    // MARK: - receive: hold-back and its hard limit

    func test_aReceivedRowIsHeldBackFromTheMomentItsPacketIsAnnounced() {
        let rig = makeRig()
        rig.coordinator.accept(event("r1", .receive))
        XCTAssertEqual(rig.coordinator.hiddenIds, ["r1"])
        XCTAssertTrue(rig.coordinator.awaitsScene("r1"))
        XCTAssertEqual(rig.coordinator.hiddenRemainingMs("r1"), 500)
    }

    func test_aHeldBackRowIsNeverHiddenForMoreThan500msWhateverHappens() {
        let rig = makeRig()
        rig.coordinator.accept(event("r1", .receive))
        // nobody resolves, nobody renders: the row row must come back by itself
        rig.clock.now += 499
        XCTAssertTrue(rig.coordinator.awaitsScene("r1"))
        XCTAssertFalse(rig.coordinator.expireHidden(), "not yet")
        rig.clock.now += 1
        XCTAssertFalse(rig.coordinator.awaitsScene("r1"), "even a view that redraws on its own must show the text now")
        XCTAssertTrue(rig.coordinator.expireHidden())
        XCTAssertTrue(rig.coordinator.hiddenIds.isEmpty)
        XCTAssertEqual(rig.effect.stalls, 1, "a packet nobody claimed is a stall")
    }

    func test_theSecondStallSwitchesTheEffectOffForTheSession() {
        let rig = makeRig()
        for i in 0..<2 {
            rig.coordinator.accept(event("r\(i)", .receive))
            rig.clock.now += 600
            rig.coordinator.expireHidden()
        }
        XCTAssertTrue(rig.effect.disabled)
        // from now on nothing is ever held back
        rig.coordinator.accept(event("r9", .receive))
        XCTAssertTrue(rig.coordinator.hiddenIds.isEmpty)
    }

    func test_aReceivedPacketWhoseRowAppearsStartsTheSceneAndReleasesTheRow() {
        let rig = makeRig()
        rig.coordinator.accept(event("r1", .receive))
        rig.clock.now += 120
        rig.coordinator.resolve(rows: [textRow("r1", outgoing: false)], foreground: true)
        XCTAssertEqual(rig.effect.activeId, "r1")
        XCTAssertEqual(rig.effect.labelKind, .verified)
        XCTAssertEqual(rig.effect.packetBytes, 90)
        XCTAssertTrue(rig.coordinator.hiddenIds.isEmpty)
        XCTAssertEqual(rig.effect.stalls, 0)
    }

    func test_withTheEffectOffNothingIsHeldBackAndNothingRemembered() {
        let rig = makeRig(level: .off)
        rig.coordinator.accept(event("r1", .receive))
        XCTAssertTrue(rig.coordinator.hiddenIds.isEmpty)
        let rig2 = makeRig(flagOn: false)
        rig2.coordinator.accept(event("r1", .receive))
        XCTAssertTrue(rig2.coordinator.hiddenIds.isEmpty)
        let rig3 = EnigmaEffect(environment: { EnigmaEnvironment(reduceMotion: true) }, seedSource: { 1 })
        rig3.configure(flagOn: true, userLevel: .full)
        let c3 = EnigmaCoordinator(effect: rig3, clock: { 5 })
        c3.conversationKey = "conv-1"
        c3.accept(event("r1", .receive))
        XCTAssertTrue(c3.hiddenIds.isEmpty, "Reduce Motion: nothing is ever hidden")
    }

    func test_anEventOfAnotherConversationOrWithNoChatAttachedIsIgnored() {
        let rig = makeRig()
        rig.coordinator.accept(event("r1", .receive, conversation: "conv-2"))
        XCTAssertTrue(rig.coordinator.hiddenIds.isEmpty)
        XCTAssertEqual(rig.coordinator.pending.size, 0)
        let detached = makeRig(conversation: nil)
        detached.coordinator.accept(event("r1", .receive))
        XCTAssertTrue(detached.coordinator.hiddenIds.isEmpty)
        XCTAssertEqual(detached.coordinator.pending.size, 0)
    }

    func test_aRowThatTurnsOutNotToBePlainTextIsReleasedAndNeverAnimated() {
        let rig = makeRig()
        rig.coordinator.accept(event("r1", .receive))
        let row = EnigmaRow(id: "r1", isOutgoing: false, kind: .other, text: "📎 file")
        rig.coordinator.resolve(rows: [row], foreground: true)
        XCTAssertNil(rig.effect.activeId)
        XCTAssertTrue(rig.coordinator.hiddenIds.isEmpty)
    }

    func test_inTheBackgroundNothingPlaysAndTheRowIsReleased() {
        let rig = makeRig()
        rig.coordinator.accept(event("r1", .receive))
        rig.coordinator.resolve(rows: [textRow("r1", outgoing: false)], foreground: false)
        XCTAssertNil(rig.effect.activeId)
        XCTAssertTrue(rig.coordinator.hiddenIds.isEmpty)
    }

    func test_aPacketForAnOutgoingRowIsNeverPlayedOnAReceivedRowAndViceVersa() {
        let rig = makeRig()
        rig.coordinator.accept(event("x1", .receive))
        rig.coordinator.resolve(rows: [textRow("x1", outgoing: true)], foreground: true)
        XCTAssertNil(rig.effect.activeId)
        rig.coordinator.accept(event("x2", .send))
        rig.coordinator.resolve(rows: [textRow("x2", outgoing: false)], foreground: true)
        XCTAssertNil(rig.effect.activeId)
    }

    // MARK: - send

    func test_aSealedPacketPlaysOnItsOutgoingRowWithTheSealedLabel() {
        let rig = makeRig()
        rig.coordinator.accept(event("s1", .send, bytes: 120))
        XCTAssertTrue(rig.coordinator.hiddenIds.isEmpty, "a sent row is never held back")
        rig.coordinator.resolve(rows: [textRow("s1", outgoing: true)], foreground: true)
        XCTAssertEqual(rig.effect.activeId, "s1")
        XCTAssertEqual(rig.effect.labelKind, .sealed)
        XCTAssertEqual(rig.effect.packetBytes, 120)
    }

    func test_aPacketAnnouncedBeforeItsRowExistsWaitsThenPlaysAndExpiresAfterFiveSeconds() {
        let rig = makeRig()
        rig.coordinator.accept(event("s1", .send))
        rig.coordinator.resolve(rows: [], foreground: true)
        XCTAssertNil(rig.effect.activeId)
        XCTAssertEqual(rig.coordinator.pending.size, 1)
        rig.clock.now += 1_000
        rig.coordinator.resolve(rows: [textRow("s1", outgoing: true)], foreground: true)
        XCTAssertEqual(rig.effect.activeId, "s1")

        let late = makeRig()
        late.coordinator.accept(event("s2", .send))
        late.clock.now += 5_001
        late.coordinator.resolve(rows: [textRow("s2", outgoing: true)], foreground: true)
        XCTAssertNil(late.effect.activeId, "history and old rows never animate")
        XCTAssertEqual(late.coordinator.pending.size, 0)
    }

    func test_aFileRowMorphsItsCleanedNameOnSendAndNeverOnReceive() {
        let rig = makeRig()
        rig.coordinator.accept(event("f1", .send, bytes: 300))
        let name = "rela\u{202E}zione\u{200B}  finale.pdf"
        rig.coordinator.resolve(rows: [EnigmaRow(id: "f1", isOutgoing: true, kind: .file, text: name)], foreground: true)
        XCTAssertEqual(rig.effect.activeId, "f1")
        XCTAssertFalse(rig.effect.frameText.contains("\u{202E}"))
        XCTAssertFalse(rig.effect.frameText.contains("\u{200B}"))

        let rx = makeRig()
        rx.coordinator.accept(event("f2", .receive))
        rx.coordinator.resolve(rows: [EnigmaRow(id: "f2", isOutgoing: false, kind: .file, text: "a.pdf")], foreground: true)
        XCTAssertNil(rx.effect.activeId)
    }

    func test_aBurstOf20ReceivedMessagesStartsOneAndQueuesThree() {
        let rig = makeRig()
        var rows: [EnigmaRow] = []
        for i in 0..<20 {
            rig.coordinator.accept(event("r\(i)", .receive))
            rows.append(textRow("r\(i)", outgoing: false))
        }
        rig.coordinator.resolve(rows: rows, foreground: true)
        // the pending list keeps the newest 8 packets (r12...r19): the older rows are released at once, never left hidden
        XCTAssertEqual(rig.effect.activeId, "r12")
        XCTAssertEqual(rig.effect.retainedScenes, 4)
        XCTAssertTrue(rig.coordinator.hiddenIds.isEmpty, "every row is visible: the extra ones show their result at once")
        XCTAssertEqual(rig.effect.stalls, 0, "a packet dropped for room is not a stall")
    }

    func test_onlyRowsNearTheEndOfTheListAnimate() {
        let rig = makeRig()
        var rows: [EnigmaRow] = []
        for i in 0..<30 { rows.append(textRow("old\(i)", outgoing: false)) }
        rig.coordinator.accept(event("old0", .receive))
        rig.coordinator.resolve(rows: rows, foreground: true)
        XCTAssertNil(rig.effect.activeId, "a row far from the end of the list is not on screen with the chat in front")
    }

    func test_stopShowsEverythingAndForgetsEverything() {
        let rig = makeRig()
        rig.coordinator.accept(event("r1", .receive))
        rig.coordinator.accept(event("r2", .receive))
        rig.coordinator.resolve(rows: [textRow("r1", outgoing: false)], foreground: true)
        rig.coordinator.stop()
        XCTAssertNil(rig.effect.activeId)
        XCTAssertEqual(rig.effect.retainedScenes, 0)
        XCTAssertTrue(rig.coordinator.hiddenIds.isEmpty)
        XCTAssertEqual(rig.coordinator.pending.size, 0)
    }

    func test_nothingGrowsAfter1000AnnouncedPackets() {
        let rig = makeRig()
        for i in 0..<1000 {
            rig.clock.now += 10
            rig.coordinator.accept(event("p\(i)", (i % 2 == 0) ? .send : .receive))
            rig.coordinator.resolve(rows: [textRow("p\(i)", outgoing: i % 2 == 0)], foreground: true)
            // let each scene run to its end so the next one can start
            var now = Int64(i) * 100_000 * ms
            var frames = 0
            while rig.effect.hasWork && frames < 2000 {
                rig.coordinator.step(nowNanos: now)
                now += 16 * ms
                frames += 1
            }
        }
        XCTAssertEqual(rig.effect.retainedScenes, 0)
        XCTAssertEqual(rig.coordinator.pending.size, 0)
        XCTAssertTrue(rig.coordinator.hiddenIds.isEmpty)
        XCTAssertEqual(rig.effect.frameText, "")
        XCTAssertFalse(rig.effect.disabled)
    }

    // MARK: - pending list

    func test_pendingIsBoundedAndDropsTheOldestAndKeepsNoDuplicates() {
        let p = EnigmaPending(maxItems: 3, ttlMs: 1_000)
        for i in 0..<5 {
            p.add(EnigmaPending.Item(id: "i\(i)", direction: .send, packetBytes: 1, wire: "AA", atMs: Int64(i)))
        }
        XCTAssertEqual(p.size, 3)
        XCTAssertFalse(p.contains(id: "i0", direction: .send))
        XCTAssertTrue(p.contains(id: "i4", direction: .send))
        p.add(EnigmaPending.Item(id: "i4", direction: .send, packetBytes: 2, wire: "BB", atMs: 6))
        XCTAssertEqual(p.size, 3)
        let taken = p.takeIf(nowMs: 7) { $0.id == "i4" }
        XCTAssertEqual(taken.count, 1)
        XCTAssertEqual(taken.first?.packetBytes, 2)
        p.expire(nowMs: 5_000)
        XCTAssertEqual(p.size, 0)
    }

    // MARK: - the bus

    @MainActor
    func test_withNoChatAttachedTheHooksReturnAtOnceAndNothingIsDelivered() {
        let bus = EnigmaBus()
        var delivered = 0
        bus.setSink { _ in delivered += 1 }
        bus.sealed(rowId: "a", conversationKey: "c", wire: Data(repeating: 1, count: 100))
        bus.opened(rowId: "b", conversationKey: "c", wire: Data(repeating: 1, count: 100))
        XCTAssertEqual(delivered, 0)
        XCTAssertFalse(bus.isActive)
    }

    @MainActor
    func test_anActiveBusDeliversTheRealSizeAndTheFirst180BytesAs240Base64Characters() {
        let bus = EnigmaBus()
        var received: [EnigmaWireEvent] = []
        bus.setSink { received.append($0) }
        bus.acquire()
        let wire = Data((0..<300).map { UInt8(truncatingIfNeeded: $0) })
        bus.sealed(rowId: "row-1", conversationKey: "conv", wire: wire)
        bus.opened(rowId: "row-2", conversationKey: "conv", wire: Data([1, 2, 3, 4]))
        XCTAssertEqual(received.count, 2)
        XCTAssertEqual(received[0].rowId, "row-1")
        XCTAssertEqual(received[0].direction, .send)
        XCTAssertEqual(received[0].packetBytes, 300)
        XCTAssertEqual(received[0].wirePrefixBase64.count, 240)
        XCTAssertEqual(Data(base64Encoded: received[0].wirePrefixBase64), wire.prefix(180))
        XCTAssertEqual(received[1].direction, .receive)
        XCTAssertEqual(received[1].packetBytes, 4)
        XCTAssertEqual(EnigmaBytes.decodedSize(base64: received[0].wirePrefixBase64), 180)
    }

    @MainActor
    func test_releaseSwitchesTheBusOffAgainAndNeverGoesNegative() {
        let bus = EnigmaBus()
        var delivered = 0
        bus.setSink { _ in delivered += 1 }
        bus.acquire()
        bus.release()
        bus.release()
        bus.release()
        XCTAssertFalse(bus.isActive)
        bus.sealed(rowId: "a", conversationKey: "c", wire: Data([1]))
        XCTAssertEqual(delivered, 0)
        bus.acquire()
        bus.sealed(rowId: "a", conversationKey: "c", wire: Data([1]))
        XCTAssertEqual(delivered, 1)
    }

    @MainActor
    func test_theHooksNeverWaitForTheAnimatorEvenWithoutOneAndAnEmptyPacketIsIgnored() {
        // The hooks are synchronous calls that return: with no sink at all (an animator that is gone or blocked elsewhere) the
        // send path simply goes on. Nothing in the bus awaits, retries or reports back.
        let bus = EnigmaBus()
        bus.acquire()
        bus.sealed(rowId: "a", conversationKey: "c", wire: Data(repeating: 9, count: 64))
        bus.opened(rowId: "b", conversationKey: "c", wire: Data(repeating: 9, count: 64))
        var delivered = 0
        bus.setSink { _ in delivered += 1 }
        bus.sealed(rowId: "c", conversationKey: "c", wire: Data())
        XCTAssertEqual(delivered, 0)
    }

    // MARK: - hook policy

    func test_onlyALivePlainTextThatOpenedReachesTheReceiveHook() {
        XCTAssertTrue(EnigmaHookPolicy.announceReceive(live: true, isRetry: false, isUndecryptablePlaceholder: false, isPlainText: true))
        XCTAssertFalse(EnigmaHookPolicy.announceReceive(live: false, isRetry: false, isUndecryptablePlaceholder: false, isPlainText: true), "history")
        XCTAssertFalse(EnigmaHookPolicy.announceReceive(live: true, isRetry: true, isUndecryptablePlaceholder: false, isPlainText: true), "a retried frame")
        XCTAssertFalse(EnigmaHookPolicy.announceReceive(live: true, isRetry: false, isUndecryptablePlaceholder: true, isPlainText: true), "failed open")
        XCTAssertFalse(EnigmaHookPolicy.announceReceive(live: true, isRetry: false, isUndecryptablePlaceholder: false, isPlainText: false), "files, view once")
    }

    // MARK: - settings and flag

    func test_theSettingDefaultsToOffAndTheFlagForcesItOffWhenOff() {
        guard let defaults = UserDefaults(suiteName: "EnigmaSettingsTests") else {
            XCTFail("suite")
            return
        }
        defaults.removePersistentDomain(forName: "EnigmaSettingsTests")
        XCTAssertEqual(EnigmaSettings.storedLevel(defaults: defaults), .off)
        EnigmaSettings.setStoredLevel(.full, defaults: defaults)
        XCTAssertEqual(EnigmaSettings.storedLevel(defaults: defaults), .full)
        XCTAssertEqual(EnigmaSettings.userLevel(flagOn: true, defaults: defaults), .full)
        XCTAssertEqual(EnigmaSettings.userLevel(flagOn: false, defaults: defaults), .off)
        EnigmaSettings.setStoredLevel(.lite, defaults: defaults)
        XCTAssertEqual(EnigmaSettings.userLevel(flagOn: true, defaults: defaults), .lite)
        defaults.set(99, forKey: EnigmaSettings.levelKey)
        XCTAssertEqual(EnigmaSettings.storedLevel(defaults: defaults), .off)
        defaults.removePersistentDomain(forName: "EnigmaSettingsTests")
        XCTAssertEqual(EnigmaSettings.flagKey, "enigma_mode.enabled")
        XCTAssertFalse(EnigmaSettings.flagDefault)
    }

    // MARK: - small pure helpers

    func test_base64DecodedSizeMatchesTheRealDecoder() {
        for n in 0...64 {
            let data = Data((0..<n).map { UInt8(truncatingIfNeeded: $0 &* 31) })
            XCTAssertEqual(EnigmaBytes.decodedSize(base64: data.base64EncodedString()), n, "n=\(n)")
        }
        XCTAssertEqual(EnigmaBytes.decodedSize(base64: ""), 0)
    }

    func test_uploadPanelFollowsTheRealProgressAndOnlyGoesForward() {
        XCTAssertEqual(EnigmaUpload.rotorIndex(0), 0, accuracy: 0)
        XCTAssertEqual(EnigmaUpload.rotorIndex(1), EnigmaUpload.span, accuracy: 1e-9)
        XCTAssertEqual(EnigmaUpload.rotorIndex(-4), 0, accuracy: 0)
        XCTAssertEqual(EnigmaUpload.rotorIndex(9), EnigmaUpload.span, accuracy: 1e-9)
        XCTAssertEqual(EnigmaUpload.rotorIndex(Double.nan), 0, accuracy: 0)
        XCTAssertEqual(EnigmaUpload.percent(0.456), 45)
        XCTAssertEqual(EnigmaUpload.percent(2), 100)
        XCTAssertEqual(EnigmaUpload.percent(Double.nan), 0)
        XCTAssertEqual(EnigmaUpload.monotonic(previous: 0.6, next: 0.2), 0.6, accuracy: 0)
        XCTAssertEqual(EnigmaUpload.monotonic(previous: 0.2, next: 0.6), 0.6, accuracy: 0)
        XCTAssertEqual(EnigmaUpload.monotonic(previous: 0.2, next: Double.nan), 0.2, accuracy: 0)
    }

    func test_sceneNameDropsFormatCharactersAndFoldsSpaces() {
        XCTAssertEqual(EnigmaText.sceneName("  a\u{202E}b\u{200B}c   d\n\te  "), "abc d e")
        XCTAssertEqual(EnigmaText.sceneName("\u{202E}\u{200B}\u{0007}"), "")
        XCTAssertEqual(EnigmaText.sceneName(""), "")
        let family = "👨‍👩‍👧‍👦.pdf"
        XCTAssertEqual(Array(EnigmaText.sceneName(family).unicodeScalars), Array(family.unicodeScalars), "joiners of emoji sequences stay")
        XCTAssertEqual(EnigmaText.sceneName("نام\u{200C}فایل"), "نام\u{200C}فایل")
    }
}
