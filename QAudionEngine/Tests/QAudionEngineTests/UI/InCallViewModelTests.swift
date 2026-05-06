import XCTest
@testable import QAudionEngine

final class InCallViewModelTests: XCTestCase {

    func test_mockIsDeterministic() {
        XCTAssertEqual(InCallViewModel.mock, InCallViewModel.mock)
    }

    func test_mockHasSecuredBadge() {
        XCTAssertEqual(InCallViewModel.mock.security, .secure)
    }

    func test_mockHasNonZeroWaveformAmplitudes() {
        let mock = InCallViewModel.mock
        XCTAssertGreaterThan(mock.waveformTx, 0)
        XCTAssertGreaterThan(mock.waveformRx, 0)
        XCTAssertGreaterThan(mock.waveformCipher, 0)
    }

    func test_mockHasMonotonicTimer() {
        XCTAssertGreaterThanOrEqual(InCallViewModel.mock.callDuration, 0)
    }

    func test_mockExposesAllControlsAsActionable() {
        let mock = InCallViewModel.mock
        XCTAssertFalse(mock.controls.isMuted)
        XCTAssertFalse(mock.controls.isSpeakerOn)
        XCTAssertFalse(mock.controls.isOnHold)
        XCTAssertEqual(mock.controls.endCallStyle, .red)
    }

    func test_mockSasPrompt_visibleOnFirstCallWithNewContact() {
        // Mock represents a first-call scenario (worst-case UX path).
        XCTAssertTrue(InCallViewModel.mock.shouldShowSasPrompt)
    }

    func test_videoPipPlaceholder_audioOnlyCallHidesIt() {
        let mock = InCallViewModel.mock
        // A.4 audio-only scope: video PiP exists in struct but is hidden.
        XCTAssertFalse(mock.showVideoPip)
    }
}
