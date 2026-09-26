import XCTest
@testable import QAudionEngine

/// `BCryptoWebSocketClient.trySend` reports whether a frame was handed to a
/// socket task, so a durable outbox can keep the frames that were not accepted.
///
/// No network is used: a client that was never connected has no socket task, and
/// nothing holds a reason to keep a socket open, so the reconnect kick that
/// `send` performs for control frames is a no-op here.
final class BCryptoWebSocketTrySendTests: XCTestCase {

    func testTrySendReportsNotAcceptedWithoutASocketTask() {
        let client = BCryptoWebSocketClient(
            config: BackendConfig(serverUrl: "https://example.invalid"))
        let payload: [String: Any] = ["group_id": "g", "server_message_id": "m"]
        let accepted: Bool = client.trySend(type: "group_msg_read", data: payload)
        XCTAssertFalse(accepted, "no socket task: the frame must be reported as not accepted")
    }
}
