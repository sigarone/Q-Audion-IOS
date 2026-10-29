import XCTest

/// Source invariants for the receive paths and the call start: no key is derived from public ids, and a frame
/// that needs a pairwise key is not opened without one. The app target has no unit-test host for `AppState`.
final class PairwiseKeyRequiredWiringTests: XCTestCase {

    private struct SourceNotFound: Error { let path: String }

    private func sourceURL(_ relativePath: String, file: StaticString = #filePath, line: UInt = #line) throws -> URL {
        var dir = URL(fileURLWithPath: "\(file)")
        for _ in 0..<10 {
            dir = dir.deletingLastPathComponent()
            let candidate = dir.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        XCTFail("\(relativePath) not found from \(file)", file: file, line: line)
        throw SourceNotFound(path: relativePath)
    }

    private func code(_ relativePath: String) throws -> String {
        let raw = try String(contentsOf: try sourceURL(relativePath), encoding: .utf8)
            .replacingOccurrences(of: "\r\n", with: "\n")
        let stripped = raw
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                if let r = line.range(of: "//") { return line[line.startIndex..<r.lowerBound] }
                return line
            }
            .joined(separator: "\n")
        return stripped.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    func testNoKeyIsDerivedFromPublicIds() throws {
        let app = try code("QAudionApp/AppState.swift")
        XCTAssertFalse(app.contains("qaudion-fallback-psk"))
        XCTAssertFalse(app.contains("deriveTransitionalSasKey"))
    }

    func testBothReceivePathsStopWithoutAPairwiseKey() throws {
        let app = try code("QAudionApp/AppState.swift")
        let parts = app.components(separatedBy: "no_pairwise_key")
        XCTAssertEqual(parts.count - 1, 1, "only the mesh path logs the line: the server path throws into the decrypt-failure policy")
        XCTAssertTrue(app.contains("case .v1, .v2: RTLog.warn(\"chat\", \"mesh msg undecryptable no_pairwise_key undec=1\") requestKeyExchangeForInbound(from: senderId) return nil"))
        XCTAssertTrue(app.contains("guard !psk.isEmpty else { throw InboundKeyError.noPairwiseKey }"))
    }

    /// The server path: a frame with no bound key is neither acknowledged nor settled; it reaches the same catch as any
    /// frame that does not open (kept, retried when a key lands, then nack and placeholder). The key request comes after
    /// the block check and goes through the per-peer throttle.
    func testAFrameWithoutAKeyIsNotAckedAndTheRequestFollowsTheBlockCheck() throws {
        let app = try code("QAudionApp/AppState.swift")
        let noKey = try XCTUnwrap(app.range(of: "psk = Data() }"))
        let head = String(app[app.index(noKey.lowerBound, offsetBy: -420)..<noKey.upperBound])
        XCTAssertFalse(head.contains("finishInboundFrame"), "the no-key branch must not ack or settle")
        XCTAssertTrue(head.contains("vaultUnreadable(peerId: senderId, vault: vault) { RTLog.warn(\"chat\", \"msg deferred vault_unreadable=1\") redeliveryPendingAfterUnlock = true return }"))
        let block = try XCTUnwrap(app.range(of: "BlockPolicy.settlesUndecryptableFrame("))
        let request = try XCTUnwrap(app.range(of: "if case InboundKeyError.noPairwiseKey = error { requestKeyExchangeForInbound(from: senderId) }"))
        XCTAssertLessThan(block.lowerBound, request.lowerBound)
        XCTAssertTrue(app.contains("guard !BlockedContactsStore.isBlocked(peerId) else { return } guard contactKeyExchange != nil else { return } guard Self.inboundKeyExchangeThrottle.isAllowed(peerId: peerId) else { return }"))
    }

    func testTheCallStartSeedsNoSessionKey() throws {
        let app = try code("QAudionApp/AppState.swift")
        XCTAssertTrue(app.contains("callPqcSessionKey = nil callPqcSessionKeyCallId = nativeSrtpOutgoingCallId pskActive = false"))
        XCTAssertTrue(app.contains("callSasKeySource = .none"))
        XCTAssertFalse(app.contains("callSasKeySource = pskActive ? .psk : .none"))
    }

    func testTheDeviceLinkScreenNeverInventsAnId() throws {
        let screen = try code("QAudionApp/Views/Settings/LinkNewDeviceScreen.swift")
        XCTAssertFalse(screen.contains("UUID()"))
        XCTAssertTrue(screen.contains("guard let userId = TokenVault.loadUserId(), !userId.isEmpty else {"))
    }

    /// The 30 s slot is taken only after the socket check, so a request that sends nothing does not block the next one.
    func testTheThrottleSlotIsTakenOnlyWhenTheRequestIsHandedOver() throws {
        let app = try code("QAudionApp/AppState.swift")
        XCTAssertTrue(app.contains("guard contactKeyExchange != nil else { return } guard Self.inboundKeyExchangeThrottle.isAllowed(peerId: peerId) else { return } Self.inboundKeyExchangeThrottle.record(peerId: peerId) triggerKeyExchange(with: peerId)"))
        XCTAssertFalse(app.contains("inboundKeyExchangeThrottle.allow("))
    }

    /// A frame deferred for a locked vault marks the app; the unlock notification clears the mark once and reconnects.
    func testUnlockRedeliversAFrameDeferredForALockedVault() throws {
        let app = try code("QAudionApp/AppState.swift")
        XCTAssertTrue(app.contains("\"msg deferred vault_unreadable=1\") redeliveryPendingAfterUnlock = true return"))
        XCTAssertTrue(app.contains("forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main ) { [weak self] _ in Task { @MainActor [weak self] in self?.redeliverPendingAfterUnlock() } }"))
        XCTAssertTrue(app.contains("guard redeliveryPendingAfterUnlock else { return } redeliveryPendingAfterUnlock = false guard isAuthenticated else { return } forceReconnectPersistentSocket(reason: \"unlock-redelivery\")"))
    }
}
