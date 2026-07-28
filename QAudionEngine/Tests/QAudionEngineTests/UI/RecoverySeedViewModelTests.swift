import XCTest
@testable import QAudionEngine

final class RecoverySeedViewModelTests: XCTestCase {

    func test_mockIsDeterministic() {
        XCTAssertEqual(RecoverySeedViewModel.mock, RecoverySeedViewModel.mock)
    }

    func test_mockHas12WordMnemonic() {
        XCTAssertEqual(RecoverySeedViewModel.mock.mnemonicWords.count, 12)
    }

    func test_mockMnemonicWordsAreLowercase() {
        for w in RecoverySeedViewModel.mock.mnemonicWords {
            XCTAssertEqual(w, w.lowercased())
        }
    }

    func test_mockStartsInSetupConfirmStep() {
        XCTAssertEqual(RecoverySeedViewModel.mock.step, .setupShowMnemonic)
    }

    func test_userConfirmedTransition() {
        var vm = RecoverySeedViewModel.mock
        vm.transition(to: .setupConfirmEntry)
        XCTAssertEqual(vm.step, .setupConfirmEntry)
    }

    func test_completedTransition() {
        var vm = RecoverySeedViewModel.mock
        vm.transition(to: .complete)
        XCTAssertEqual(vm.step, .complete)
    }

    func test_recoveryHashLength() {
        let hash = RecoverySeedViewModel.computeRecoveryHash(
            mnemonic: ["abandon", "ability", "able", "about", "above", "absent", "absorb", "abstract", "absurd", "abuse", "access", "accident"]
        )
        XCTAssertEqual(hash.count, 64)  // hex SHA-256
    }
}
