import XCTest
@testable import QAudionEngine

final class OnboardingFlowViewModelTests: XCTestCase {

    func test_mockStartsAtWelcome() {
        XCTAssertEqual(OnboardingFlowViewModel.mock.step, .welcome)
    }

    func test_advancingForward() {
        let vm = OnboardingFlowViewModel.mock.advancing(to: .authChoice)
        XCTAssertEqual(vm.step, .authChoice)
    }

    func test_advancingRejectsBackward() {
        let vm = OnboardingFlowViewModel(step: .recoverySetup).advancing(to: .welcome)
        XCTAssertEqual(vm.step, .recoverySetup)
    }

    func test_skippedRecoveryTracked() {
        let vm = OnboardingFlowViewModel.mock.markingSkipped(recovery: true)
        XCTAssertTrue(vm.skippedRecovery)
    }

    func test_canSkipDefaults() {
        XCTAssertTrue(OnboardingFlowViewModel.mock.canSkipRecovery)
    }

    func test_doneIsFinalStep() {
        let vm = OnboardingFlowViewModel(step: .done)
        let attempted = vm.advancing(to: .welcome)  // should be no-op
        XCTAssertEqual(attempted.step, .done)
    }
}
