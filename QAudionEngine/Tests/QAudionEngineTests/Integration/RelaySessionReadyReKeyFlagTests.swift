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
        integ.onRelaySessionReady = { _, _, _ in seen.append(integ.relaySessionReadyIsReKey) }

        let key = Data(repeating: 0x42, count: 32)
        integ.fireRelaySessionReady(key, callId: "ab7f643b-1e6c-4e0f-bc93-1682e09ad24b", isReKey: false, generation: 0)
        integ.fireRelaySessionReady(key, callId: "ab7f643b-1e6c-4e0f-bc93-1682e09ad24b", isReKey: true, generation: 0)
        integ.fireRelaySessionReady(key, callId: "ab7f643b-1e6c-4e0f-bc93-1682e09ad24b", isReKey: false, generation: 0)

        XCTAssertEqual(seen, [false, true, false])
        XCTAssertFalse(integ.relaySessionReadyIsReKey, "the flag must not outlive the callback")
    }

    func testCallbackStillReceivesTheKeyAndCallIdOnAReKeyRound() {
        let integ = QAudionCallIntegration()
        var got: (Data, String)?
        integ.onRelaySessionReady = { key, cid, _ in got = (key, cid) }

        let key = Data(repeating: 0x07, count: 32)
        integ.fireRelaySessionReady(key, callId: "call-1", isReKey: true, generation: 0)

        XCTAssertEqual(got?.0, key, "message-PSK persistence in the app still needs the re-keyed key")
        XCTAssertEqual(got?.1, "call-1")
    }

    func testCallbackReceivesTheGenerationItWasFiredWith() {
        // W-STALESEALER (fix-3) — `fireRelaySessionReady`'s `generation` is a pure
        // pass-through to the callback; the integration itself never inspects it.
        let integ = QAudionCallIntegration()
        var seenGeneration: Int?
        integ.onRelaySessionReady = { _, _, generation in seenGeneration = generation }

        let key = Data(repeating: 0x11, count: 32)
        integ.fireRelaySessionReady(key, callId: "call-2", isReKey: false, generation: 42)

        XCTAssertEqual(seenGeneration, 42)
    }
}
