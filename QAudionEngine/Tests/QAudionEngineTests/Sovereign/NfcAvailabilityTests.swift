import XCTest
@testable import QAudionEngine

/// A device that cannot read NFC tags (an iPad, for instance) must get a
/// neutral line instead of the NFC actions, and starting an exchange there
/// must report that line without touching CoreNFC.
final class NfcAvailabilityTests: XCTestCase {

    func test_injectedAnswerIsReported() {
        XCTAssertTrue(NfcAvailability { true }.isAvailable)
        XCTAssertFalse(NfcAvailability { false }.isAvailable)
    }

    func test_unavailableMessageIsNotEmptyAndNotPhrasedAsAnError() {
        let message: String = NfcAvailability.unavailableMessage
        XCTAssertFalse(message.isEmpty)
        XCTAssertFalse(message.lowercased().contains("errore"))
        XCTAssertFalse(message.lowercased().contains("error"))
    }

    func test_startWithoutNfcReportsTheUnavailableLine() {
        let exchange = NfcApduExchange(availability: NfcAvailability { false })
        exchange.localIdentityPublicKey = Data(repeating: 0x01, count: 32)
        var seen: [NfcApduExchange.State] = []
        exchange.onStateChanged = { seen.append($0) }

        exchange.start()

        XCTAssertEqual(exchange.state, .error(NfcAvailability.unavailableMessage))
        XCTAssertEqual(seen, [.error(NfcAvailability.unavailableMessage)])
    }
}
