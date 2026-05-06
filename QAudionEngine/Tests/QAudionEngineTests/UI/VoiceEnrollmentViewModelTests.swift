import XCTest
@testable import QAudionEngine

final class VoiceEnrollmentViewModelTests: XCTestCase {

    func test_mockIsDeterministic() {
        XCTAssertEqual(VoiceEnrollmentViewModel.mock, VoiceEnrollmentViewModel.mock)
    }

    func test_mockHas5Prompts() {
        XCTAssertEqual(VoiceEnrollmentViewModel.mock.prompts.count, 5)
        XCTAssertEqual(VoiceEnrollmentViewModel.mock.totalPrompts, 5)
    }

    func test_mockStartsInIntroduction() {
        XCTAssertEqual(VoiceEnrollmentViewModel.mock.step, .introduction)
    }

    func test_progressFraction_atStart_isZero() {
        XCTAssertEqual(VoiceEnrollmentViewModel.mock.progressFraction, 0)
    }

    func test_progressFraction_halfwayDone() {
        let vm = VoiceEnrollmentViewModel(
            prompts: ["a", "b", "c", "d"],
            completedPromptsCount: 2
        )
        XCTAssertEqual(vm.progressFraction, 0.5)
    }

    func test_transition_introToPromptShowing() {
        var vm = VoiceEnrollmentViewModel.mock
        vm.transition(to: .promptShowing(prompt: "test"))
        if case .promptShowing(let p) = vm.step {
            XCTAssertEqual(p, "test")
        } else {
            XCTFail("Expected .promptShowing")
        }
    }

    func test_transition_recording() {
        var vm = VoiceEnrollmentViewModel.mock
        vm.transition(to: .promptShowing(prompt: "test"))
        vm.transition(to: .recording(prompt: "test", secondsElapsed: 1.5))
        if case .recording(_, let sec) = vm.step {
            XCTAssertEqual(sec, 1.5)
        } else {
            XCTFail("Expected .recording")
        }
    }

    func test_transition_complete() {
        var vm = VoiceEnrollmentViewModel.mock
        vm.transition(to: .complete(speakerEmbeddingId: "embed-123"))
        if case .complete(let id) = vm.step {
            XCTAssertEqual(id, "embed-123")
        } else {
            XCTFail("Expected .complete")
        }
    }

    func test_transition_rejectsBackward() {
        var vm = VoiceEnrollmentViewModel.mock
        vm.transition(to: .processing)
        // Trying to go back to introduction should be rejected.
        vm.transition(to: .introduction)
        XCTAssertEqual(vm.step, .processing)
    }

    func test_transition_completeToRestart_isAllowed() {
        var vm = VoiceEnrollmentViewModel.mock
        vm.transition(to: .complete(speakerEmbeddingId: "x"))
        vm.transition(to: .introduction)  // user restarts enrollment
        XCTAssertEqual(vm.step, .introduction)
    }
}
