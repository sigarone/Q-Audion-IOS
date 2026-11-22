import XCTest

/// The app side of the contact shield over the chat sessions' bindings: every site that installs a CHAT or CONTROL session hands the
/// fingerprint of the peer key it authenticated, the shield work stays off the main actor, the traffic marker is written only by real
/// traffic, and the wipe drops what is remembered. Source invariants, like `IdentityVerdictWiringTests` (comments stripped, whitespace
/// collapsed): the app target cannot be driven from here.
final class SessionBindingWiringTests: XCTestCase {

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
        throw NSError(domain: "SessionBindingWiringTests", code: 1)
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

    func testEverySiteThatInstallsAChatOrControlSessionHandsThePeerKeyPrint() throws {
        let app = try code("QAudionApp/AppState.swift")
        let replaces = ranges(of: ".replaceChannelSession(", in: app)
        // call handshake (answering leg and calling leg), CHAT and CONTROL each, plus the CONTROL of the pre-bootstrap
        XCTAssertEqual(replaces.count, 5)
        for r in replaces {
            let call = String(app[r.lowerBound...].prefix(260))
            XCTAssertTrue(call.contains("peerKeyPrint: peerKeyPrint"), "a replace without the print: \(call)")
        }
        let ensures = ranges(of: ".ensureBootstrapped(", in: app)
        XCTAssertEqual(ensures.count, 1)
        for r in ensures {
            XCTAssertTrue(String(app[r.lowerBound...].prefix(200)).contains("peerKeyPrint: peerKeyPrint"))
        }
        // The print is the safety number of the key the handshake (or the envelope) authenticated, computed one way.
        XCTAssertEqual(ranges(of: "ContactShieldEvaluator.peerKeyPrint(peerUserId: peerId, key: peerIdentityPub)", in: app).count, 2)
        XCTAssertEqual(ranges(of: "ContactShieldEvaluator.peerKeyPrint(peerUserId: peer, key: peerIdentityEdPub)", in: app).count, 1)
    }

    func testTheBindingNamesAKeyOnlyWhenThatRoundsSignatureVerifiedUnderIt() throws {
        let engine = try code("QAudionEngine/Sources/QAudionEngine/Integration/QAudionCallIntegration.swift")
        XCTAssertTrue(engine.contains("onV4BootstrapReady?(callerId, combined, verifiedOfferBinding, selfId, peerId, offerSigOk, callId)"))
        XCTAssertTrue(engine.contains("onV4BootstrapReady?(callerId, combined, sentBinding, selfId, peerId, acceptSigOk, callId)"))
        let app = try code("QAudionApp/AppState.swift")
        XCTAssertEqual(ranges(of: "peerIdentityPub, peerKeyVerified, handshakeCallId in", in: app).count, 2)
        XCTAssertEqual(ranges(of: "bindPrint ? ContactShieldEvaluator.peerKeyPrint(peerUserId: peerId, key: peerIdentityPub) : nil", in: app).count, 2)
    }

    func testTheDetailScreenReadsTheSharedCacheAndTheProviderRebuildKeepsThePublishedSets() throws {
        let detail = try code("QAudionApp/Views/Contacts/ContactDetailScreen.swift")
        XCTAssertFalse(detail.contains("ContactShieldEvaluator."), "the detail screen does no shield work of its own")
        XCTAssertTrue(detail.contains("ContactShieldCache.shared"))
        let evaluator = try code("QAudionApp/Services/ContactShieldEvaluator.swift")
        XCTAssertTrue(evaluator.contains("static func configure(kmsClient: BCryptoKmsClient?) { source.set(kmsClient) }")
                      || evaluator.contains("static func configure(kmsClient: BCryptoKmsClient?) { source.set(kmsClient)"),
                      "a new or missing provider only swaps who is asked")
        XCTAssertTrue(evaluator.contains("guard source.hasClient, !cache.isFresh(peerUserId: peerUserId) else { return }"))
    }

    func testTheShieldWorkRunsOffTheMainActorAndCannotLoseAPeerUpdate() throws {
        let cache = try code("QAudionApp/Services/ContactShieldCache.swift")
        let head = try XCTUnwrap(cache.range(of: "final class ContactShieldCache: ObservableObject"))
        let workerStart = try XCTUnwrap(cache.range(of: "private final class ContactShieldWorker"))
        let mainActorPart = String(cache[head.lowerBound..<workerStart.lowerBound])
        for forbidden in ["ContactShieldEvaluator.", "ContactsStore(", "PeerIdentityPinStore(", "PeerSessionBindings"] {
            XCTAssertFalse(mainActorPart.contains(forbidden), "the main-actor part must not do the work: \(forbidden)")
        }
        let worker = String(cache[workerStart.lowerBound...])
        XCTAssertTrue(worker.contains("DispatchQueue(label: \"qaudion.contactshield\""))
        XCTAssertTrue(worker.contains("ContactShieldEvaluator.shields("))
        // one set of dirty peers, emptied before the work and refilled by every mark, which always schedules a drain
        XCTAssertTrue(worker.contains("dirtyPeers.insert(peer)"))
        XCTAssertTrue(worker.contains("let peers = dirtyPeers allDirty = false dirtyPeers = []"))
        // one serial place publishes the whole map with a sequence number; a map older than the one shown is dropped
        XCTAssertTrue(worker.contains("sequence += 1 publish?(sequence, current)"))
        XCTAssertTrue(cache.contains("guard sequence > lastSequence else { return }"))
        XCTAssertTrue(cache.contains("MessageRatchet.bindingDidChangeNotification"))
        XCTAssertTrue(cache.contains("PublishedDeviceSetCache.didChangeNotification"))
    }

    func testTheHeaderShieldSitsNextToTheNameAndTheSecondaryButtonMovesToTheMenuOnANarrowScreen() throws {
        let chat = try code("QAudionApp/Views/Chat/ChatDetailScreen.swift")
        let bar = try XCTUnwrap(chat.range(of: "private var topBar: some View {"))
        let top = String(chat[bar.lowerBound...])
        let name = try XCTUnwrap(top.range(of: "Text(resolvedPeerTitle)"))
        let badge = try XCTUnwrap(top.range(of: "ContactShieldBadge(userId:"))
        let spacer = try XCTUnwrap(top.range(of: "Spacer(minLength: 6)"))
        XCTAssertTrue(name.lowerBound < badge.lowerBound && badge.lowerBound < spacer.lowerBound, "the shield follows the name, before the buttons")
        XCTAssertEqual(ranges(of: "ContactShieldBadge(userId:", in: chat).count, 1)
        XCTAssertTrue(chat.contains("horizontalSizeClass == .compact"))
        XCTAssertTrue(chat.contains("if MeshFeature.enabled, !headerIsNarrow {"))
        XCTAssertTrue(chat.contains("if MeshFeature.enabled, headerIsNarrow { meshMenuButton }"))
    }

    func testTrafficIsWrittenOnlyByAcceptedCallsVerifiedContentAndTheBootstrapNeverByAPin() throws {
        let app = try code("QAudionApp/AppState.swift")
        XCTAssertTrue(app.contains("if report.round <= 1, !report.isProofReport { noteCallTraffic(report) }"))
        let kms = try XCTUnwrap(app.range(of: "private static func bootstrapV4FromPreBootstrap("))
        XCTAssertTrue(String(app[kms.lowerBound...]).contains("ContactShieldEvaluator.noteTraffic(peerUserId: peer, deviceId: nil, key: peerIdentityEdPub)"))
        let receiver = try code("QAudionApp/Services/ChatFileAttachmentReceiver.swift")
        let note = try XCTUnwrap(receiver.range(of: "ContactShieldEvaluator.noteTraffic("))
        let pin = try XCTUnwrap(receiver.range(of: "PeerIdentityPinStore().pinOrMatch("))
        let verify = try XCTUnwrap(receiver.range(of: "FileAttachmentAnnounceSig.verify("))
        XCTAssertTrue(verify.lowerBound < note.lowerBound, "traffic is noted after the announce verified")
        XCTAssertTrue(note.lowerBound < pin.lowerBound, "and it is not the pin that writes it")
        // no pin path writes it: the evaluator is not reached from the pin store or the trust evaluator
        for path in ["QAudionApp/Services/PeerTrustEvaluator.swift", "QAudionEngine/Sources/QAudionEngine/Persistence/PeerIdentityPinStore.swift"] {
            XCTAssertFalse(try code(path).contains("noteTraffic"), path)
        }
    }

    func testTheSessionClientFeedsThePublishedSetAndTheWipeDropsTheBindings() throws {
        let app = try code("QAudionApp/AppState.swift")
        XCTAssertTrue(app.contains("ContactShieldPublished.configure(kmsClient: liveProvider?.kmsClient)"))
        let wipe = try code("QAudionApp/Services/LocalCryptoWipe.swift")
        XCTAssertTrue(wipe.contains("KeychainRatchetVault().wipeAll() MessageRatchet.bindingsVaultWiped()"))
    }

    func testTheRowsOfAHandWrittenContactRebuildKeepTheTrafficField() throws {
        for path in ["QAudionApp/Views/ContactsListView.swift", "QAudionApp/Views/Contacts/PhoneContactImportView.swift"] {
            XCTAssertTrue(try code(path).contains("lastTrafficAtMs: existing?.lastTrafficAtMs"), path)
        }
        XCTAssertTrue(try code("QAudionEngine/Sources/QAudionEngine/Persistence/ContactsStore.swift").contains("lastTrafficAtMs: base.lastTrafficAtMs"))
    }
}
