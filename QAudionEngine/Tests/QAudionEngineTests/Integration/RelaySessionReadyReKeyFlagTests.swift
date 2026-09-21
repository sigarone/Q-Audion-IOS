import XCTest
@testable import QAudionEngine

/// W-M15SEALERONCE (2026-09-20). The M-15 outer relay seal belongs to the
/// call's FIRST handshake; a re-key round must not rebuild it (Android installs
/// it exactly once per call). The integration tells the app which kind of
/// handshake completion `onRelaySessionReady` is for through
/// `relaySessionReadyIsReKey`, which the app reads synchronously inside the
/// callback. These tests pin that contract: visible to the callback, cleared
/// afterwards, and never left set for the next (first-handshake) completion.
final class RelaySessionReadyReKeyFlagTests: XCTestCase {

    func testFlagIsFalseByDefault() {
        let integ = QAudionCallIntegration()
        XCTAssertFalse(integ.relaySessionReadyIsReKey)
    }

    func testCallbackSeesTheRoundKindAndFlagIsClearedAfterwards() {
        let integ = QAudionCallIntegration()
        var seen: [Bool] = []
        integ.onRelaySessionReady = { _, _ in seen.append(integ.relaySessionReadyIsReKey) }

        let key = Data(repeating: 0x42, count: 32)
        integ.fireRelaySessionReady(key, callId: "ab7f643b-1e6c-4e0f-bc93-1682e09ad24b", isReKey: false)
        integ.fireRelaySessionReady(key, callId: "ab7f643b-1e6c-4e0f-bc93-1682e09ad24b", isReKey: true)
        integ.fireRelaySessionReady(key, callId: "ab7f643b-1e6c-4e0f-bc93-1682e09ad24b", isReKey: false)

        XCTAssertEqual(seen, [false, true, false])
        XCTAssertFalse(integ.relaySessionReadyIsReKey, "the flag must not outlive the callback")
    }

    func testCallbackStillReceivesTheKeyAndCallIdOnAReKeyRound() {
        let integ = QAudionCallIntegration()
        var got: (Data, String)?
        integ.onRelaySessionReady = { key, cid in got = (key, cid) }

        let key = Data(repeating: 0x07, count: 32)
        integ.fireRelaySessionReady(key, callId: "call-1", isReKey: true)

        XCTAssertEqual(got?.0, key, "message-PSK persistence in the app still needs the re-keyed key")
        XCTAssertEqual(got?.1, "call-1")
    }
}
