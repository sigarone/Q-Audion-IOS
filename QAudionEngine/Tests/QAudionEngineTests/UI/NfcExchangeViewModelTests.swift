import XCTest
@testable import QAudionEngine

final class NfcExchangeViewModelTests: XCTestCase {

    func test_mockIsDeterministic() {
        XCTAssertEqual(NfcExchangeViewModel.mock, NfcExchangeViewModel.mock)
    }

    func test_mockStartsInIdle() {
        XCTAssertEqual(NfcExchangeViewModel.mock.state, .idle)
    }

    func test_stateMachine_idleToWaiting() {
        var vm = NfcExchangeViewModel.mock
        vm.transition(to: .waiting)
        XCTAssertEqual(vm.state, .waiting)
    }

    func test_stateMachine_waitingToExchanging() {
        var vm = NfcExchangeViewModel.mock
        vm.transition(to: .waiting)
        vm.transition(to: .exchanging)
        XCTAssertEqual(vm.state, .exchanging)
    }

    func test_stateMachine_exchangingToSuccess() {
        var vm = NfcExchangeViewModel.mock
        vm.transition(to: .waiting)
        vm.transition(to: .exchanging)
        vm.transition(to: .success(peerDeviceName: "Pixel 7"))
        if case .success(let peer) = vm.state {
            XCTAssertEqual(peer, "Pixel 7")
        } else {
            XCTFail("Expected .success state")
        }
    }

    func test_stateMachine_exchangingToError() {
        var vm = NfcExchangeViewModel.mock
        vm.transition(to: .waiting)
        vm.transition(to: .exchanging)
        vm.transition(to: .error(message: "Tag dropped"))
        if case .error(let msg) = vm.state {
            XCTAssertEqual(msg, "Tag dropped")
        } else {
            XCTFail("Expected .error state")
        }
    }

    func test_stateMachine_rejectsBackwardTransition() {
        var vm = NfcExchangeViewModel.mock
        vm.transition(to: .waiting)
        vm.transition(to: .exchanging)
        // Going back to .idle from .exchanging is not allowed; stay put.
        vm.transition(to: .idle)
        XCTAssertEqual(vm.state, .exchanging)
    }
}
