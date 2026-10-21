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

    // MARK: - W-NFCSAS: sasConfirm state

    func test_stateMachine_exchangingToSasConfirmToSuccess() {
        var vm = NfcExchangeViewModel.mock
        vm.transition(to: .waiting)
        vm.transition(to: .exchanging)
        vm.transition(to: .sasConfirm(sas: "482917", peerDeviceName: "Pixel 7"))
        if case .sasConfirm(let sas, let peer) = vm.state {
            XCTAssertEqual(sas.count, 6)
            XCTAssertEqual(peer, "Pixel 7")
        } else {
            XCTFail("Expected .sasConfirm state")
        }
        vm.transition(to: .success(peerDeviceName: "Pixel 7"))
        if case .success(let peer) = vm.state {
            XCTAssertEqual(peer, "Pixel 7")
        } else {
            XCTFail("Expected .success state")
        }
    }

    func test_stateMachine_sasConfirmToError_userRejected() {
        var vm = NfcExchangeViewModel.mock
        vm.transition(to: .waiting)
        vm.transition(to: .exchanging)
        vm.transition(to: .sasConfirm(sas: "482917", peerDeviceName: "Pixel 7"))
        vm.transition(to: .error(message: "SAS non confermato — scambio annullato"))
        if case .error(let msg) = vm.state {
            XCTAssertEqual(msg, "SAS non confermato — scambio annullato")
        } else {
            XCTFail("Expected .error state")
        }
    }

    /// Structural pin: `sasConfirm` MUST rank strictly between `exchanging`
    /// and `success`/`error` — this is what makes `exchanging -> sasConfirm`
    /// and `sasConfirm -> success` both legal forward hops, matching exactly
    /// the sequence `NfcApduExchange.runPhase14cExchange` actually drives
    /// (derive PSK -> .sasConfirm -> await confirmation -> .success). A
    /// future edit that reordered these ranks would silently break that
    /// real code path even though this state machine's own generic
    /// "any forward hop is legal" rule wouldn't catch it directly.
    func test_sasConfirmRank_isStrictlyBetweenExchangingAndSuccess() {
        var beforeSas = NfcExchangeViewModel.mock
        beforeSas.transition(to: .waiting)
        beforeSas.transition(to: .exchanging)
        beforeSas.transition(to: .sasConfirm(sas: "000000", peerDeviceName: "x"))
        XCTAssertEqual(beforeSas.state, .sasConfirm(sas: "000000", peerDeviceName: "x"),
                       "exchanging -> sasConfirm must be a legal forward hop")

        var afterSas = NfcExchangeViewModel.mock
        afterSas.transition(to: .waiting)
        afterSas.transition(to: .exchanging)
        afterSas.transition(to: .sasConfirm(sas: "000000", peerDeviceName: "x"))
        afterSas.transition(to: .success(peerDeviceName: "x"))
        XCTAssertEqual(afterSas.state, .success(peerDeviceName: "x"),
                       "sasConfirm -> success must be a legal forward hop")
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

    // MARK: - NFC pairing v2: the second tap

    func test_twoTapFlow_isAChainOfLegalHops() {
        var vm = NfcExchangeViewModel.mock
        vm.transition(to: .waiting)
        vm.transition(to: .exchanging)
        vm.transition(to: .sasConfirm(sas: "123456", peerDeviceName: "Anna"))
        vm.transition(to: .holdAgain(peerDeviceName: "Anna"))
        XCTAssertEqual(vm.state, .holdAgain(peerDeviceName: "Anna"))
        vm.transition(to: .confirming(peerDeviceName: "Anna"))
        vm.transition(to: .waitingForPeer(peerDeviceName: "Anna"))
        XCTAssertEqual(vm.state, .waitingForPeer(peerDeviceName: "Anna"))
        vm.transition(to: .success(peerDeviceName: "Anna"))
        XCTAssertEqual(vm.state, .success(peerDeviceName: "Anna"))
        vm.transition(to: .idle)
        XCTAssertEqual(vm.state, .idle)
    }

    func test_secondTapThatEndsUndecidedGoesBackToHoldAgain() {
        var vm = NfcExchangeViewModel.mock
        vm.transition(to: .holdAgain(peerDeviceName: "Anna"))
        vm.transition(to: .confirming(peerDeviceName: "Anna"))
        vm.transition(to: .waitingForPeer(peerDeviceName: "Anna"))
        vm.transition(to: .holdAgain(peerDeviceName: "Anna"))
        XCTAssertEqual(vm.state, .holdAgain(peerDeviceName: "Anna"))
    }

    func test_peerRejectedIsTerminalUntilDismissed() {
        var vm = NfcExchangeViewModel.mock
        vm.transition(to: .confirming(peerDeviceName: "Anna"))
        vm.transition(to: .peerRejected(peerDeviceName: "Anna"))
        XCTAssertEqual(vm.state, .peerRejected(peerDeviceName: "Anna"))
        vm.transition(to: .confirming(peerDeviceName: "Anna"))
        XCTAssertEqual(vm.state, .peerRejected(peerDeviceName: "Anna"), "no way back into the exchange")
        vm.transition(to: .idle)
        XCTAssertEqual(vm.state, .idle)
    }
}
