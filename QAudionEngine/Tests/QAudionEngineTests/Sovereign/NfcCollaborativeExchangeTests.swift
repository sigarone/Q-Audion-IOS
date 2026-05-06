import XCTest
@testable import QAudionEngine

final class NfcCollaborativeExchangeTests: XCTestCase {

    func test_initialState_isIdle() {
        let svc = NfcCollaborativeExchange()
        XCTAssertEqual(svc.viewModel.state, .idle)
    }

    func test_start_movesToWaiting() {
        let svc = NfcCollaborativeExchange()
        svc.start()
        XCTAssertEqual(svc.viewModel.state, .waiting)
    }

    func test_simulateTagDetected_movesToExchanging() {
        let svc = NfcCollaborativeExchange()
        svc.start()
        svc.simulateTagDetectedForTesting()
        XCTAssertEqual(svc.viewModel.state, .exchanging)
    }

    func test_simulateSuccess_recordsPeerName() throws {
        let svc = NfcCollaborativeExchange()
        svc.start()
        svc.simulateTagDetectedForTesting()
        svc.simulateExchangeCompletedForTesting(peerDeviceName: "Pixel 7")
        if case .success(let name) = svc.viewModel.state {
            XCTAssertEqual(name, "Pixel 7")
        } else { XCTFail("Expected .success(peerDeviceName:) but got \(svc.viewModel.state)") }
    }

    func test_simulateError_movesToError() {
        let svc = NfcCollaborativeExchange()
        svc.start()
        svc.simulateTagDetectedForTesting()
        svc.simulateExchangeFailedForTesting(message: "Timeout")
        if case .error(let msg) = svc.viewModel.state {
            XCTAssertEqual(msg, "Timeout")
        } else { XCTFail("Expected .error(message:) but got \(svc.viewModel.state)") }
    }
}
