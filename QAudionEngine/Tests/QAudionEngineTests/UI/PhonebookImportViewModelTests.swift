import XCTest
@testable import QAudionEngine

final class PhonebookImportViewModelTests: XCTestCase {

    // MARK: - Determinism

    func test_mockIsDeterministic() {
        XCTAssertEqual(PhonebookImportViewModel.mock, PhonebookImportViewModel.mock)
    }

    // MARK: - Mock content

    func test_mockHas2Matches() {
        guard case .results(let matched, _) = PhonebookImportViewModel.mock.step else {
            return XCTFail("Expected .results step in mock")
        }
        XCTAssertEqual(matched.count, 2)
    }

    func test_mockUnmatchedCount() {
        guard case .results(_, let unmatched) = PhonebookImportViewModel.mock.step else {
            return XCTFail("Expected .results step in mock")
        }
        XCTAssertEqual(unmatched, 47)
    }

    func test_mockTotalLocalContacts() {
        XCTAssertEqual(PhonebookImportViewModel.mock.totalLocalContacts, 49)
    }

    func test_mockPermissionDeniedIsFalse() {
        XCTAssertFalse(PhonebookImportViewModel.mock.permissionDenied)
    }

    // MARK: - Step transitions

    func test_transition_forwardOrder_succeeds() {
        var vm = PhonebookImportViewModel(step: .introduction)
        vm.transition(to: .requestingPermission)
        XCTAssertEqual(vm.step, .requestingPermission)

        vm.transition(to: .scanning(progress: 0.5))
        if case .scanning(let p) = vm.step {
            XCTAssertEqual(p, 0.5)
        } else {
            XCTFail("Expected .scanning")
        }

        vm.transition(to: .discovering(progress: 0.0))
        if case .discovering(let p) = vm.step {
            XCTAssertEqual(p, 0.0)
        } else {
            XCTFail("Expected .discovering")
        }

        vm.transition(to: .results(matched: [], unmatched: 0))
        if case .results(let m, let u) = vm.step {
            XCTAssertTrue(m.isEmpty)
            XCTAssertEqual(u, 0)
        } else {
            XCTFail("Expected .results")
        }
    }

    func test_transition_backwardBlocked() {
        // Start at .discovering, try to go back to .scanning — should be ignored.
        var vm = PhonebookImportViewModel(step: .discovering(progress: 0.8))
        vm.transition(to: .scanning(progress: 0.0))
        if case .discovering(let p) = vm.step {
            XCTAssertEqual(p, 0.8, "Backward transition should be ignored")
        } else {
            XCTFail("Step should remain .discovering")
        }
    }

    func test_transition_fromError_allowsRestart() {
        var vm = PhonebookImportViewModel(step: .error(message: "oops"))
        vm.transition(to: .introduction)
        XCTAssertEqual(vm.step, .introduction, "Restart from .error should be allowed")
    }

    func test_transition_fromResults_allowsRestart() {
        var vm = PhonebookImportViewModel(
            step: .results(matched: [], unmatched: 5)
        )
        vm.transition(to: .introduction)
        XCTAssertEqual(vm.step, .introduction, "Restart from .results should be allowed")
    }
}
