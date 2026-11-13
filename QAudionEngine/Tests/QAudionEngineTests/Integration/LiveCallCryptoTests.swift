import XCTest
@testable import QAudionEngine

/// The key state of a call (`LiveCallCrypto`): the shared vectors of the rekey rules (base choice, retention, offer spacing,
/// deferral, who rekeys) and the behaviour that guards a real failure: the caller adopts its call, a hangup closes the state
/// without a deadlock, two OFFERs admitted together both install, the frame-key latch follows a replacement, a close wipes
/// every key.
final class LiveCallCryptoTests: XCTestCase {

    // MARK: - Helpers

    private func load() throws -> [String: Any] {
        let candidates: [URL?] = [
            Bundle.module.url(forResource: "pqc-hardening-v1-kat", withExtension: "json"),
            Bundle.module.url(forResource: "pqc-hardening-v1-kat", withExtension: "json", subdirectory: "kat"),
            Bundle.module.url(forResource: "pqc-hardening-v1-kat", withExtension: "json", subdirectory: "Resources/kat")
        ]
        let url = try XCTUnwrap(candidates.compactMap { $0 }.first, "pqc-hardening-v1-kat.json is not in the test bundle")
        let object = try JSONSerialization.jsonObject(with: try Data(contentsOf: url), options: [])
        return try XCTUnwrap(object as? [String: Any])
    }

    private func vectors(_ name: String) throws -> [[String: Any]] {
        let chain = try XCTUnwrap(try load()["rekeyChain"] as? [String: Any])
        let section = try XCTUnwrap(chain[name] as? [String: Any], name)
        return try XCTUnwrap(section["vectors"] as? [[String: Any]], name)
    }

    private func features(chain: Bool, fk: Bool = false, inner: Bool = false, caller: Bool = true) -> LiveCallCrypto.Features {
        LiveCallCrypto.Features(
            ext: true, rekeyChainV1: chain, frameKeyV6: fk, innerSealV2: inner,
            ownCapabilities: AndroidHandshakeBundle.Capabilities(ratchetV3: true), ownTag: true, peerTag: true, selfIsCaller: caller)
    }

    private func key(_ seed: Int) -> Data {
        Data(repeating: UInt8(truncatingIfNeeded: seed), count: 32)
    }

    private func adopted(
        chain: Bool, fk: Bool = false, inner: Bool = false, role: LiveCallCrypto.Role = .offerer, id: String = "kat-call"
    ) throws -> LiveCallCrypto {
        try XCTUnwrap(LiveCallCrypto.adopt(
            callId: id, role: role, features: features(chain: chain, fk: fk, inner: inner, caller: role == .offerer),
            sessionKey: key(1)))
    }

    private func epochs(_ list: Any?) -> [Int32] {
        ((list as? [NSNumber]) ?? []).map { $0.int32Value }.sorted()
    }

    private let tokenZero: [[UInt8]] = [Array("0".utf8)]

    // MARK: - rekeyChain.baseSelection

    func testTheBaseIsTheGreatestConfirmedRoundWhoseChainKeyIsRetained() throws {
        let list = try vectors("baseSelection")
        XCTAssertEqual(list.count, 5)
        for v in list {
            let name = v["name"] as? String ?? "?"
            let confirmed = epochs(v["confirmedRounds"])
            let retained = epochs(v["retainedChainKeys"])
            let object = try adopted(chain: true)
            for epoch in Set(confirmed + retained).sorted() where epoch > 0 {
                XCTAssertEqual(object.stageRound(epoch: epoch, sessionKey: key(Int(epoch) + 1), ours: true, handle: nil), .staged, name)
            }
            for epoch in confirmed { _ = object.confirmRound(epoch: epoch) }
            for epoch in object.snapshot().rounds where !retained.contains(epoch) { object.eraseChainKeyForTesting(epoch: epoch) }
            XCTAssertEqual(object.snapshot().retained, retained, name)
            XCTAssertEqual(object.selectBase(), (v["expectBase"] as? NSNumber)?.int32Value, name)
        }
    }

    // MARK: - rekeyChain.retention

    func testAChainKeyIsErasedOnceTwoLaterRoundsAreConfirmed() throws {
        let list = try vectors("retention")
        XCTAssertEqual(list.count, 3)
        for v in list {
            let name = v["name"] as? String ?? "?"
            let object = try adopted(chain: true)
            let steps = try XCTUnwrap(v["steps"] as? [[String: Any]], name)
            for step in steps {
                let event = step["event"] as? String ?? ""
                let epoch = (step["round"] as? NSNumber)?.int32Value ?? -1
                switch event {
                case "derive":
                    if epoch > 0 {
                        XCTAssertEqual(object.stageRound(epoch: epoch, sessionKey: key(Int(epoch) + 1), ours: true, handle: nil), .staged, name)
                    }
                case "confirm":
                    _ = object.confirmRound(epoch: epoch)
                case "abandon":
                    _ = object.failRound(epoch: epoch)
                default:
                    XCTFail("unknown event \(event) in \(name)")
                }
                XCTAssertEqual(object.snapshot().retained, epochs(step["retainedAfter"]), "\(name) after \(event) \(epoch)")
            }
        }
    }

    // MARK: - rekeyChain.offerSpacing, triggerDeferral, offerer

    func testOffersAreSpacedByFiveSecondsAndOneRoundAtATime() throws {
        let list = try vectors("offerSpacing")
        XCTAssertEqual(list.count, 5)
        // A call whose only tag is the per-round inner seal is spaced by the same rules.
        for (chain, inner) in [(true, false), (false, false), (false, true)] {
            for v in list {
                let name = "\(v["name"] as? String ?? "?") chain=\(chain) inner=\(inner)"
                let object = try adopted(chain: chain, fk: !chain && !inner, inner: inner)
                _ = object.confirmRound(epoch: 0)
                let undecided = v["ownRoundUndecided"] as? Bool ?? false
                if let previous = (v["previousOfferHandedOverAtMs"] as? NSNumber)?.intValue {
                    guard case .granted = object.reserveOwn(epoch: 1) else { return XCTFail("reserve \(name)") }
                    object.markOffered(epoch: 1, nowMs: previous)
                    if !undecided { _ = object.abandonOwn(epoch: 1) }
                }
                let now = (v["nowMs"] as? NSNumber)?.intValue ?? 0
                let expect = (v["expect"] as? [String: Any])?["verdict"] as? String
                let gate = object.checkOffer(nowMs: now)
                XCTAssertEqual(gate == .go, expect == "send", name)
            }
        }
    }

    func testARekeyTriggerBeforeTheFirstRoundIsConfirmedIsDeferredOnceAndReArmedOnce() throws {
        let list = try vectors("triggerDeferral")
        XCTAssertEqual(list.count, 4)
        for v in list {
            let name = v["name"] as? String ?? "?"
            let tagged = v["callNegotiatedRekeyChainV1"] as? Bool ?? false
            let object = try adopted(chain: tagged)
            let confirmed = v["round1KcmacVerified"] as? Bool ?? false
            let expectDefer = ((v["expect"] as? [String: Any])?["verdict"] as? String) == "defer"
            if confirmed { _ = object.confirmRound(epoch: 0) }
            let first = object.checkOffer(nowMs: 0)
            XCTAssertEqual(first == .go, !expectDefer, name)
            if expectDefer {
                XCTAssertEqual(first, .deferred(.chain, timerMs: nil), name)
                XCTAssertEqual(object.checkOffer(nowMs: 1), .deferred(.chain, timerMs: nil), "\(name): coalesced")
                XCTAssertEqual(object.confirmRound(epoch: 0).rearm, .chain, "\(name): one re-arm when the first round is confirmed")
                XCTAssertNil(object.confirmRound(epoch: 0).rearm, "\(name): not twice")
            }
        }
    }

    func testOnlyTheCallerOfAChainedCallDropsARekeyOfferSignedByTheCallee() throws {
        let list = try vectors("offerer")
        XCTAssertEqual(list.count, 2)
        for v in list {
            let name = v["name"] as? String ?? "?"
            let calleeSigned = (v["signer"] as? String) == "callee"
            // the callee-signed OFFER reaches the caller; the caller-signed one reaches the callee
            let drops = RekeyOffererRule.dropsCalleeRekeyOffer(liveIsChainedOfferer: calleeSigned, exactIdMatches: true, round: 2)
            XCTAssertEqual(drops, ((v["expect"] as? [String: Any])?["verdict"] as? String) == "drop_silent", name)
        }
        for chained in [false, true] {
            for exact in [false, true] {
                for round in [nil, 0, 1, 2, 7] as [Int?] {
                    let expected = chained && exact && round != nil && round != 1
                    XCTAssertEqual(
                        RekeyOffererRule.dropsCalleeRekeyOffer(liveIsChainedOfferer: chained, exactIdMatches: exact, round: round),
                        expected, "chained=\(chained) exact=\(exact) round=\(String(describing: round))")
                }
            }
        }
    }

    func testTheRoleFactsOfTheLiveObjectDecideTheDrop() throws {
        let integration = QAudionCallIntegration()
        XCTAssertNil(integration.liveRoleFacts(exactCallId: "ID-1"), "no key state, no facts: today's path")
        _ = integration.adoptLiveForTesting(callId: "ID-1", role: .offerer, features: features(chain: true), sessionKey: key(1))
        XCTAssertEqual(integration.liveRoleFacts(exactCallId: "ID-1"), LiveRoleFacts(isChainedOfferer: true, exactIdMatches: true))
        XCTAssertEqual(integration.liveRoleFacts(exactCallId: "id-1"), LiveRoleFacts(isChainedOfferer: true, exactIdMatches: false),
                       "the id is compared exactly")
        _ = integration.adoptLiveForTesting(callId: "ID-2", role: .offerer, features: features(chain: false), sessionKey: key(1))
        XCTAssertEqual(integration.liveRoleFacts(exactCallId: "ID-2")?.isChainedOfferer, false, "an untagged call keeps today's path")
        _ = integration.adoptLiveForTesting(callId: "ID-3", role: .acceptor, features: features(chain: true, caller: false), sessionKey: key(1))
        XCTAssertEqual(integration.liveRoleFacts(exactCallId: "ID-3")?.isChainedOfferer, false, "the callee answers rekey OFFERs")
    }

    // MARK: - Adoption (the caller never has the offer binding)

    func testTheCallerAdoptsOnItsOwnOfferIdAndTheCalleeOnItsBoundOffer() throws {
        let caller = QAudionCallIntegration()
        let wanted = features(chain: true)
        XCTAssertNil(caller.liveAdopt(callId: "ABC-1", role: .offerer, features: wanted, sessionKey: key(1), capsEpoch: caller.capsBindState.epoch),
                     "no OFFER sent: nothing to answer")
        caller.didSendOutgoingCallOffer(callId: "ABC-1")
        XCTAssertNil(caller.boundOfferCallIdForTesting, "the caller never takes the binding of an inbound OFFER")
        let adopted = try XCTUnwrap(caller.liveAdopt(
            callId: "abc-1", role: .offerer, features: wanted, sessionKey: key(1), capsEpoch: caller.capsBindState.epoch),
                                    "the ACCEPT echoes the id in another case and still answers the OFFER")
        XCTAssertEqual(adopted.callId, "ABC-1", "the object keeps the exact id of the OFFER that was sent")
        XCTAssertTrue(caller.liveAdopt(callId: "abc-1", role: .offerer, features: wanted, sessionKey: key(1), capsEpoch: caller.capsBindState.epoch) === adopted,
                      "adopting twice returns the same object")
        XCTAssertNil(caller.liveAdopt(callId: "other", role: .offerer, features: wanted, sessionKey: key(1), capsEpoch: caller.capsBindState.epoch))
        XCTAssertNil(caller.liveAdopt(callId: "abc-1", role: .offerer, features: wanted, sessionKey: key(1), capsEpoch: caller.capsBindState.epoch + 1),
                     "a call that ended meanwhile adopts nothing")

        let callee = QAudionCallIntegration()
        let calleeFeatures = features(chain: true, caller: false)
        XCTAssertNil(callee.liveAdopt(callId: "XYZ-9", role: .acceptor, features: calleeFeatures, sessionKey: key(1), capsEpoch: callee.capsBindState.epoch),
                     "an OFFER that did not take the binding adopts nothing")
        callee.bindOfferCallForTesting(callId: "XYZ-9")
        XCTAssertEqual(callee.liveAdopt(callId: "XYZ-9", role: .acceptor, features: calleeFeatures, sessionKey: key(1), capsEpoch: callee.capsBindState.epoch)?.callId, "XYZ-9")
    }

    // MARK: - Hangup

    func testAHangupWithAKeyStateAndALeaseReturnsAndWipesBoth() throws {
        let integration = QAudionCallIntegration()
        integration.configureAsActiveCallerForTesting()
        let object = try XCTUnwrap(integration.adoptLiveForTesting(
            callId: "call-x", role: .offerer, features: features(chain: true), sessionKey: key(1)))
        _ = object.confirmRound(epoch: 0)
        guard case .granted(let granted) = object.reserveOwn(epoch: 1), let lease = granted else { return XCTFail("no lease") }
        _ = try integration.installWaitingReKeyAttemptForTesting(round: 2) { _ in }
        integration.setPendingLeaseForTesting(lease)

        let returned = expectation(description: "onCallEnded returned")
        DispatchQueue.global().async {
            integration.onCallEnded()
            returned.fulfill()
        }
        wait(for: [returned], timeout: 10)
        XCTAssertTrue(lease.isWipedForTesting, "the copy of the chain key is wiped")
        XCTAssertTrue(object.isClosed)
        XCTAssertNil(integration.liveForTesting)
    }

    // MARK: - Two OFFERs admitted together

    func testTwoOffersAdmittedTogetherBothInstallWhateverTheOrderOfStaging() throws {
        let object = try adopted(chain: true, role: .acceptor)
        _ = object.confirmRound(epoch: 0)
        guard case .admitted(let three) = object.gateAccept(epoch: 3, offerSigOk: true, chainBaseTokens: tokenZero) else {
            return XCTFail("E3 admitted")
        }
        guard case .admitted(let four) = object.gateAccept(epoch: 4, offerSigOk: true, chainBaseTokens: tokenZero) else {
            return XCTFail("E4 admitted")
        }
        XCTAssertEqual(object.snapshot().reservations, 2)
        XCTAssertEqual(object.stageRound(epoch: 4, sessionKey: key(4), ours: false, handle: four), .staged)
        XCTAssertEqual(object.stageRound(epoch: 3, sessionKey: key(3), ours: false, handle: three), .staged,
                       "the lower round stages after the higher one: a normal install, not a refusal")
        let snapshot = object.snapshot()
        XCTAssertEqual(snapshot.rounds, [0, 3, 4])
        XCTAssertEqual(snapshot.reservations, 0)
        XCTAssertEqual(snapshot.maxAdmittedE, 4)
        XCTAssertEqual(snapshot.maxStagedE, 4)

        if case .staleEpoch = object.gateAccept(epoch: 2, offerSigOk: true, chainBaseTokens: tokenZero) {} else {
            XCTFail("a lower round after E4 was admitted is stale at the gate")
        }
        if case .staleEpoch = object.gateAccept(epoch: 4, offerSigOk: true, chainBaseTokens: tokenZero) {} else {
            XCTFail("a second copy of the same OFFER is stale at the gate")
        }
        XCTAssertEqual(object.snapshot(), snapshot, "a refusal at the gate writes nothing")
    }

    func testAnUnsignedOfferNeverRaisesTheAdmittedWatermark() throws {
        let object = try adopted(chain: true, role: .acceptor)
        _ = object.confirmRound(epoch: 0)
        guard case .admitted(let unsigned) = object.gateAccept(epoch: 9, offerSigOk: false, chainBaseTokens: tokenZero) else {
            return XCTFail("admitted")
        }
        XCTAssertEqual(object.snapshot().maxAdmittedE, 0)
        object.abandon(handle: unsigned)
        if case .admitted = object.gateAccept(epoch: 2, offerSigOk: true, chainBaseTokens: tokenZero) {} else {
            XCTFail("the next signed round is admitted")
        }
    }

    func testARefusedChainBaseConsumesNothingAndTheCallGoesOn() throws {
        let object = try adopted(chain: true, role: .acceptor)
        _ = object.confirmRound(epoch: 0)
        let before = object.snapshot()
        let cases: [(name: String, tokens: [[UInt8]], why: RekeyChain.Refusal)] = [
            ("missing", [], .missing),
            ("duplicate", [Array("0".utf8), Array("0".utf8)], .duplicate),
            ("malformed", [Array("00".utf8)], .malformed),
            ("not below", [Array("3".utf8)], .notBelow),
            ("no key", [Array("2".utf8)], .noCk)
        ]
        for c in cases {
            if case .refused(let why) = object.gateAccept(epoch: 3, offerSigOk: true, chainBaseTokens: c.tokens) {
                XCTAssertEqual(why, c.why, c.name)
            } else {
                XCTFail("\(c.name) must be refused")
            }
        }
        XCTAssertEqual(object.snapshot(), before)
        XCTAssertEqual(object.chainRefusalEpoch, 3, "sticky, for the level line")
        if case .admitted = object.gateAccept(epoch: 3, offerSigOk: true, chainBaseTokens: tokenZero) {} else {
            XCTFail("the next honest round is accepted")
        }
    }

    // MARK: - Close

    func testACloseWipesEveryKeyAndEveryHandleAndRefusesWhatFollows() throws {
        let acceptor = try adopted(chain: true, role: .acceptor)
        _ = acceptor.confirmRound(epoch: 0)
        guard case .admitted(let handle) = acceptor.gateAccept(epoch: 2, offerSigOk: true, chainBaseTokens: tokenZero),
              let reserved = handle.lease else { return XCTFail("admitted with a lease") }
        let offerer = try adopted(chain: true, role: .offerer)
        _ = offerer.confirmRound(epoch: 0)
        guard case .granted(let own) = offerer.reserveOwn(epoch: 1), let ownLease = own else { return XCTFail("granted with a lease") }

        acceptor.close()
        offerer.close()
        acceptor.close()
        XCTAssertTrue(reserved.isWipedForTesting)
        XCTAssertTrue(ownLease.isWipedForTesting)
        XCTAssertNil(ownLease.deriveSessionKey(pqcSharedSecret: key(2), x25519Shared: key(3), psk: nil, acceptHash: key(4)),
                     "a closed lease derives nothing")
        XCTAssertTrue(acceptor.snapshot().rounds.isEmpty)
        XCTAssertEqual(acceptor.stageRound(epoch: 5, sessionKey: key(5), ours: false, handle: nil), .closed)
        if case .closed = acceptor.gateAccept(epoch: 9, offerSigOk: true, chainBaseTokens: tokenZero) {} else { XCTFail("closed") }
        if case .refused = offerer.reserveOwn(epoch: 9) {} else { XCTFail("closed") }
        XCTAssertEqual(offerer.checkOffer(nowMs: 0), .closed)
    }

    func testAChainKeyBufferIsOverwrittenAndReadsNothingAfterTheWipe() {
        let buffer = ChainKeyBuffer(copying: key(7))
        XCTAssertEqual(buffer.withBytes { Data($0) }, key(7))
        let copy = buffer.duplicate()
        buffer.wipe()
        XCTAssertTrue(buffer.isWipedForTesting)
        XCTAssertNil(buffer.withBytes { Data($0) })
        XCTAssertEqual(copy?.withBytes { Data($0) }, key(7), "a duplicate owns its own bytes")
        copy?.wipe()
        XCTAssertNil(buffer.duplicate())
    }

    // MARK: - The frame-key latch

    func testTheLatchFollowsAReplacementOfTheCallsKeyState() throws {
        let integration = QAudionCallIntegration()
        let first = try XCTUnwrap(integration.adoptLiveForTesting(
            callId: "abc", role: .acceptor, features: features(chain: false, fk: true, caller: false), sessionKey: key(1)))
        let provider = QAudionCallIntegration.makeFrameKeyModeProvider(wireCallId: "ABC", integrations: [integration])
        let latch = FrameKeyLatch()
        guard case .v6(_, let firstGen) = latch.resolve(provider()).mode else { return XCTFail("v6 expected") }
        XCTAssertEqual(firstGen, first.gen)

        // a newer round-1 OFFER replaced the unanswered one: the integration holds only the new object, the old one is not closed
        let second = try XCTUnwrap(LiveCallCrypto.adopt(
            callId: "abc", role: .acceptor, features: features(chain: false, fk: true, caller: false), sessionKey: key(2)))
        integration.swapLiveForTesting(second)
        XCTAssertFalse(first.isClosed)
        XCTAssertTrue(integration.isLiveClosed(gen: first.gen))
        guard case .v6(_, let secondGen) = latch.resolve(provider()).mode else { return XCTFail("v6 expected") }
        XCTAssertEqual(secondGen, second.gen, "the latch moved to the new object")

        // another object while the latched one is the current open one is withheld, never re-typed
        let other = QAudionCallIntegration()
        _ = other.adoptLiveForTesting(callId: "abc", role: .acceptor, features: features(chain: false, fk: false, caller: false), sessionKey: key(3))
        let foreign = QAudionCallIntegration.makeFrameKeyModeProvider(wireCallId: "abc", integrations: [other])
        XCTAssertEqual(latch.resolve(foreign()).mode, .pending)
        XCTAssertEqual(latch.resolve(provider()).mode, .v6(callIdL: "abc", gen: second.gen))
    }

    func testTheProviderAnswersFromAnyThreadAndWithholdsAnotherCall() throws {
        let integration = QAudionCallIntegration()
        _ = integration.adoptLiveForTesting(
            callId: "abc", role: .offerer, features: features(chain: false, fk: true), sessionKey: key(1))
        let provider = QAudionCallIntegration.makeFrameKeyModeProvider(wireCallId: "ABC", integrations: [integration])
        let other = QAudionCallIntegration.makeFrameKeyModeProvider(wireCallId: "different", integrations: [integration])
        let answered = expectation(description: "answered off the main thread")
        DispatchQueue.global().async {
            XCTAssertFalse(Thread.isMainThread)
            XCTAssertNotEqual(provider().mode, .pending)
            XCTAssertEqual(other().mode, .pending, "a key state of another call never answers")
            answered.fulfill()
        }
        wait(for: [answered], timeout: 10)
    }

    // MARK: - Log lines

    private final class LineBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        func add(_ line: String) { lock.lock(); stored.append(line); lock.unlock() }
        var lines: [String] { lock.lock(); defer { lock.unlock() }; return stored }
    }

    /// Every line the key state writes is one of the closed shapes the log shipper admits: words and digits, no id, no key.
    func testEveryLineOfTheKeyStateMatchesTheShippedVocabulary() throws {
        let box = LineBox()
        CapsBindLog.setSink { box.add($0) }
        defer { CapsBindLog.setSink(nil) }

        let caller = QAudionCallIntegration()
        caller.didSendOutgoingCallOffer(callId: "C-1")
        let object = try XCTUnwrap(caller.liveAdopt(
            callId: "c-1", role: .offerer, features: features(chain: true, fk: true), sessionKey: key(1), capsEpoch: caller.capsBindState.epoch))
        XCTAssertFalse(caller.liveOfferGate(object), "deferred until the first round is confirmed")
        caller.liveConfirm(gen: object.gen, round: 1)
        XCTAssertEqual(caller.liveStage(object, epoch: 1, sessionKey: key(2), ours: true, handle: nil), .staged)
        caller.liveFail(gen: object.gen, round: 2)
        caller.onCallEnded()

        let callee = QAudionCallIntegration()
        callee.bindOfferCallForTesting(callId: "C-2")
        let acceptor = try XCTUnwrap(callee.liveAdopt(
            callId: "C-2", role: .acceptor, features: features(chain: true, caller: false), sessionKey: key(3), capsEpoch: callee.capsBindState.epoch))
        callee.liveConfirm(gen: acceptor.gen, round: 1)
        if case .refused = callee.liveGate(acceptor, epoch: 3, offerSigOk: true, tokens: []) {} else { XCTFail("refused") }
        callee.onCallEnded()

        // The per-round inner seal writes its own lines: a stage, a refusal and the switch of the send pointer.
        let sealed = QAudionCallIntegration()
        sealed.didSendOutgoingCallOffer(callId: "C-3")
        let sealedObject = try XCTUnwrap(sealed.liveAdopt(
            callId: "c-3", role: .offerer, features: features(chain: false, inner: true), sessionKey: key(4),
            capsEpoch: sealed.capsBindState.epoch))
        XCTAssertEqual(sealed.liveStage(sealedObject, epoch: 1, sessionKey: key(5), ours: true, handle: nil), .staged)
        XCTAssertEqual(sealed.liveStage(sealedObject, epoch: 257, sessionKey: key(6), ours: true, handle: nil), .slotCollision)
        sealed.liveConfirm(gen: sealedObject.gen, round: 2)
        sealed.onCallEnded()

        let shapes = [
            "^live adopt gen=[0-9]{1,9} role=[01] chain=[01] fk=[56]$",
            "^live close gen=[0-9]{1,9} staged=[0-9]{1,2} why=[1-4]$",
            "^live chain refuse round=[0-9]{1,10} why=[1-7]$",
            "^live defer why=[1-3]$",
            "^live stage round=[0-9]{1,10} chain=[01] staged=[0-9]{1,2}$",
            "^live confirm round=[0-9]{1,10} retained=[0-9]{1,2}$",
            "^live fail round=[0-9]{1,10}$",
            "^live offerer drop round=[0-9]{1,10}$",
            "^live fk why=[1-3]$",
            "^live inner stage round=[0-9]{1,10} slots=[0-9]{1,2}$",
            "^live inner switch round=[0-9]{1,10} prev=[0-9]{1,10}$",
            "^live inner refuse round=[0-9]{1,10} why=[1-4]$",
            "^capsbind ext=[01] own=[01] peer=[01] round=[0-9]{1,10} chain=[01] fk=[01]$"
        ]
        let expressions = try shapes.map { try NSRegularExpression(pattern: $0) }
        let lines = box.lines
        XCTAssertGreaterThanOrEqual(lines.count, 8)
        for line in lines {
            let range = NSRange(line.startIndex..., in: line)
            XCTAssertTrue(expressions.contains { $0.firstMatch(in: line, range: range) != nil }, "not a shipped shape: \(line)")
        }
    }

    // MARK: - Wire shape

    func testTheTwoTagsAndTheBaseRoundAreWrittenOnlyWhenOn() throws {
        let off = AndroidHandshakeBundle(
            kind: .offer, callId: "c", pqcPublicKey: "", x25519PublicKey: "",
            capabilities: AndroidHandshakeBundle.Capabilities(ratchetV3: true, capsBindV1: true))
        let offText = AndroidHandshakeEnvelope.jsonPayload(of: off)
        XCTAssertFalse(offText.contains("rekeyChainV1"))
        XCTAssertFalse(offText.contains("frameKeyV6"))
        XCTAssertFalse(offText.contains("innerSealV2"))
        XCTAssertFalse(offText.contains("chainBase"))
        let on = AndroidHandshakeBundle(
            kind: .offer, callId: "c", pqcPublicKey: "", x25519PublicKey: "",
            capabilities: AndroidHandshakeBundle.Capabilities(ratchetV3: true, capsBindV1: true, rekeyChainV1: true, frameKeyV6: true),
            rekeyRound: 3, chainBase: 2)
        let onText = AndroidHandshakeEnvelope.jsonPayload(of: on)
        XCTAssertTrue(onText.contains("\"rekeyChainV1\":true"))
        XCTAssertTrue(onText.contains("\"frameKeyV6\":true"))
        XCTAssertTrue(onText.contains("\"chainBase\":2"))
        let analysis = CapsBind.analyze(json: onText)
        XCTAssertTrue(analysis.tags.contains("rekeyChainV1"))
        XCTAssertEqual(analysis.chainBaseTokens, [Array("2".utf8)])
        let decoded = try JSONDecoder().decode(AndroidHandshakeBundle.self, from: Data(onText.utf8))
        XCTAssertNil(decoded.chainBase, "the typed decode never reads the base: the validated text does")
        XCTAssertTrue(QAudionCallIntegration.rekeyChainV1Enabled)
        XCTAssertTrue(QAudionCallIntegration.frameKeyV6Enabled)
        XCTAssertTrue(QAudionCallIntegration.innerSealV2Enabled)

        // The inner seal tag is written only when advertised, and survives the copy that every signed bundle goes through.
        let sealedOn = AndroidHandshakeBundle(
            kind: .offer, callId: "c", pqcPublicKey: "", x25519PublicKey: "",
            capabilities: AndroidHandshakeBundle.Capabilities(ratchetV3: true, capsBindV1: true, innerSealV2: true).with(sigHybridV1: true))
        let sealedText = AndroidHandshakeEnvelope.jsonPayload(of: sealedOn)
        XCTAssertTrue(sealedText.contains("\"innerSealV2\":true"))
        XCTAssertTrue(CapsBind.analyze(json: sealedText).tags.contains("innerSealV2"))
        let sealedOff = AndroidHandshakeBundle(
            kind: .offer, callId: "c", pqcPublicKey: "", x25519PublicKey: "",
            capabilities: AndroidHandshakeBundle.Capabilities(ratchetV3: true, capsBindV1: true).with(sigHybridV1: true))
        XCTAssertFalse(AndroidHandshakeEnvelope.jsonPayload(of: sealedOff).contains("innerSealV2"))
    }
}
