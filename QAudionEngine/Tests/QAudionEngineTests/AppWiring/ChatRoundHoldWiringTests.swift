import XCTest

/// A first call round whose peer signature did not verify, or that was aborted, does not change the chat sessions by itself.
/// Its install is kept for the call and applied only when the call's confirmation releases it. The app target cannot be driven
/// from here, so the app side is pinned as source invariants (comments stripped, whitespace collapsed), like
/// `SessionBindingWiringTests`. The engine-level behaviour (an install without a print leaves the binding unknown, a replaced pair
/// converges and chats both ways) is exercised in `MessageRatchetV4RoutedTests` and `SessionBindingStoreTests`.
final class ChatRoundHoldWiringTests: XCTestCase {

    private func code(_ relativePath: String, file: StaticString = #filePath) throws -> String {
        var dir = URL(fileURLWithPath: "\(file)")
        for _ in 0..<10 {
            dir = dir.deletingLastPathComponent()
            let candidate = dir.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                let raw = try String(contentsOf: candidate, encoding: .utf8)
                return raw.split(separator: "\n", omittingEmptySubsequences: false)
                    .map { line -> Substring in
                        if let r = line.range(of: "//") { return line[line.startIndex..<r.lowerBound] }
                        return line
                    }
                    .joined(separator: "\n")
                    .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            }
        }
        XCTFail("\(relativePath) not found: the wiring invariants cannot run")
        throw NSError(domain: "ChatRoundHoldWiringTests", code: 1)
    }

    private func ranges(of needle: String, in source: String) -> [Range<String.Index>] {
        var out: [Range<String.Index>] = []
        var from = source.startIndex
        while let r = source.range(of: needle, range: from..<source.endIndex) {
            out.append(r)
            from = r.upperBound
        }
        return out
    }

    /// The text of each of the two `onV4BootstrapReady` closures, up to the next wiring call.
    private func bootstrapClosures(_ app: String) throws -> [String] {
        let starts = ranges(of: "integration.onV4BootstrapReady = {", in: app)
        XCTAssertEqual(starts.count, 2)
        return try starts.map { r in
            let tail = String(app[r.lowerBound...])
            let end = try XCTUnwrap(tail.range(of: "wireCapsBind(on: integration)"))
            return String(tail[..<end.lowerBound])
        }
    }

    func testTheHandshakeHandsItsCallIdToTheBootstrapHook() throws {
        let engine = try code("QAudionEngine/Sources/QAudionEngine/Integration/QAudionCallIntegration.swift")
        XCTAssertTrue(engine.contains("public var onV4BootstrapReady: ((String, Data, Data, Data, Data, Bool, String) -> Void)?"))
        XCTAssertEqual(ranges(of: "onV4BootstrapReady?(", in: engine).count, 2)
        XCTAssertTrue(engine.contains("verifiedOfferBinding, selfId, peerId, offerSigOk, callId)"))
        XCTAssertTrue(engine.contains("sentBinding, selfId, peerId, acceptSigOk, callId)"))
    }

    func testAnUnverifiedRoundIsHeldUnderTheHandshakeCallIdBeforeAnythingIsInstalled() throws {
        let app = try code("QAudionApp/AppState.swift")
        for closure in try bootstrapClosures(app) {
            let hold = try XCTUnwrap(closure.range(of: "guard peerKeyVerified else { self.holdChatRound(handshakeCallId: handshakeCallId, round: round) return }"))
            let activeCall = try XCTUnwrap(closure.range(of: "getActiveCallId()"))
            XCTAssertTrue(hold.lowerBound < activeCall.lowerBound, "the hold does not depend on the active call or on a hold flag set elsewhere")
            XCTAssertFalse(closure.contains("bootstrap(false)"))
            XCTAssertTrue(closure.contains("bindPrint ? ContactShieldEvaluator.peerKeyPrint(peerUserId: peerId, key: peerIdentityPub) : nil"))
            // a verified round installs at once and drops an older held candidate of the same call
            XCTAssertTrue(closure.contains("self.pendingChatRounds[handshakeCallId.lowercased()] = nil"))
            XCTAssertFalse(closure.contains("bootstrap()"), "no unconditional install is left")
        }
    }

    func testAHeldRoundIsKeptOnlyForALiveCallAndDroppedOtherwise() throws {
        let app = try code("QAudionApp/AppState.swift")
        let start = try XCTUnwrap(app.range(of: "private func holdChatRound("))
        let body = String(app[start.lowerBound...].prefix(1000))
        XCTAssertTrue(app.contains("return !cid.isEmpty && (activeId == cid || RingSignalingRegistry.shared.entry(cid) != nil)"))
        XCTAssertTrue(body.contains("guard isLiveCallId(cid) else { RTLog.info(\"call\", \"CHAT-REKEY discarded\") return }"))
        XCTAssertTrue(body.contains("pendingChatRounds[cid] = round RTLog.info(\"call\", \"CHAT-REKEY held\")"))
    }

    func testTheConfirmationAppliesTheHeldRoundAndTheBindingNamesTheKeyOnlyWhenItIsTheRoundsKey() throws {
        let app = try code("QAudionApp/AppState.swift")
        let apply = try XCTUnwrap(app.range(of: "private func applyHeldChatRound("))
        let body = String(app[apply.lowerBound...].prefix(1000))
        XCTAssertTrue(body.contains("bind = bindKey != nil && bindKey == round.peerIdentityPub"))
        XCTAssertTrue(body.contains("round.install(bind)"))
        XCTAssertTrue(body.contains("bind ? \"CHAT-REKEY applied\" : \"CHAT-REKEY applied_release\""))
        // frames that failed to open while the round was held sit in the one-to-one retry buffer: they are retried now
        XCTAssertTrue(body.contains("retryBufferedOneToOneMessages(for: peerId)"))
        // the release path applies it (both modes), and the release-only mode passes no key
        XCTAssertTrue(app.contains("if applyChatRound { applyHeldChatRound(callId: cid, bindKey: bindKey) }"))
        XCTAssertTrue(app.contains("case .releaseOnly: RTLog.info(\"call\", \"sasConfirm release=1 rec=0\") confirmIdentityAndReleaseMedia(markSasConfirmed: false) return .releasedOnly"))
        // an adopted rotation binds the adopted key after the adoption succeeded, and applies with no key when it did not
        XCTAssertTrue(app.contains("confirmIdentityAndReleaseMedia(markSasConfirmed: false, applyChatRound: false)"))
        XCTAssertTrue(app.contains("callIdentityAuth = next applyHeldChatRound(callId: cid, bindKey: candidate.key)"))
        XCTAssertEqual(ranges(of: "applyHeldChatRound(callId: cid, bindKey: nil)", in: app).count, 2)
        XCTAssertEqual(ranges(of: "confirmIdentityAndReleaseMedia(bindKey: key)", in: app).count, 2)
    }

    func testTheHeldRoundIsDroppedWithTheCallTheRingAndAReplacingRound() throws {
        let app = try code("QAudionApp/AppState.swift")
        XCTAssertTrue(app.contains("pendingIdentityGatedMedia[cid] = nil discardHeldChatRound(callId: cid)"))
        XCTAssertTrue(app.contains("pendingIdentityGatedMedia.removeValue(forKey: gatedCallId) discardHeldChatRound(callId: gatedCallId)"))
        XCTAssertTrue(app.contains("pendingAcceptGatedActions[callId] = nil discardHeldChatRound(callId: callId)"))
    }

    func testTheOnlyNewLogLinesAreTheClosedVocabulary() throws {
        let app = try code("QAudionApp/AppState.swift")
        for word in ["held", "applied", "applied_release", "discarded", "buffer_drop"] {
            XCTAssertTrue(app.contains("\"CHAT-REKEY \(word)\""), word)
        }
        XCTAssertEqual(ranges(of: "CHAT-REKEY", in: app).count, 6)
    }

    func testWaitingFramesOutliveTheFinalTimerWhileARoundIsHeld() throws {
        let app = try code("QAudionApp/AppState.swift")
        let fin = try XCTUnwrap(app.range(of: "private func finalizeBufferedOneToOneMessages(for senderId: String) {"))
        XCTAssertTrue(String(app[fin.upperBound...].prefix(200)).contains("if hasHeldRound(for: senderId) { return }"))
        let discard = try XCTUnwrap(app.range(of: "private func discardHeldChatRound("))
        let body = String(app[discard.lowerBound...].prefix(900))
        XCTAssertTrue(body.contains("bufferedOneToOneCiphertexts[i].bufferedAtMs = nowMs"))
        XCTAssertTrue(body.contains("scheduleBufferedOneToOneFinalize(for: peerId)"))
        // the cap keeps the newest frames
        XCTAssertTrue(app.contains("firstIndex(where: { !hasHeldRound(for: $0.senderId) })"))
        XCTAssertTrue(app.contains("bufferedOneToOneCiphertexts.removeFirst() RTLog.info(\"call\", \"CHAT-REKEY buffer_drop\")"))
    }

    /// Source scan (the app target cannot be driven): the call-derived message key of a held round is written only by the apply.
    func testTheMessageKeyOfAHeldRoundIsWrittenOnlyByTheApply() throws {
        let app = try code("QAudionApp/AppState.swift")
        // no call site writes it directly any more: the one direct write is inside the helper's unheld branch
        XCTAssertEqual(ranges(of: "persistMessagePsk(sessionKey:", in: app).count, 3, "the definition, the helper's unheld branch and the held closure")
        XCTAssertEqual(ranges(of: "persistOrHoldMessagePsk(sessionKey:", in: app).count, 3, "the definition and the two legs")
        XCTAssertEqual(ranges(of: "held: roundHeld)", in: app).count, 2)
        XCTAssertEqual(ranges(of: "let roundHeld: Bool = integration?.isMediaHeld(callId: cid) ?? false", in: app).count, 2, "read before the hop")
        let apply = try XCTUnwrap(app.range(of: "private func applyHeldChatRound("))
        XCTAssertTrue(String(app[apply.lowerBound...].prefix(1000)).contains("psk?.persist()"))
        let discard = try XCTUnwrap(app.range(of: "private func discardHeldChatRound("))
        XCTAssertTrue(String(app[discard.lowerBound...].prefix(400)).contains("pendingMsgPsks.removeValue(forKey: cid)"))
    }

    func testAConfirmationThatComesBeforeTheHoldAppliesTheRoundWhenItLands() throws {
        let app = try code("QAudionApp/AppState.swift")
        XCTAssertTrue(app.contains("releasedChatCalls[cid] = bindKey ?? Data()"))
        XCTAssertTrue(app.contains("guard let key = releasedChatCalls[cid] else { return }"))
        XCTAssertTrue(app.contains("applyHeldChatRound(callId: cid, bindKey: key.isEmpty ? nil : key)"))
        XCTAssertEqual(ranges(of: "applyIfAlreadyReleased(cid)", in: app).count, 2, "after a round lands and after a key lands")
    }

    func testTheControlFailureQuorumPausesWhileARoundIsHeld() throws {
        let app = try code("QAudionApp/AppState.swift")
        let guardRange = try XCTUnwrap(app.range(of: "if hasHeldRound(for: senderId) { return } let diverged = AppState.controlFailureTracker.record("))
        XCTAssertNotNil(guardRange)
    }
}
