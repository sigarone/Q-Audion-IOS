import XCTest
@testable import QAudionEngine

final class ChatSettingsViewModelTests: XCTestCase {

    func test_mockIsDeterministic() {
        XCTAssertEqual(ChatSettingsViewModel.mock, ChatSettingsViewModel.mock)
    }

    func test_mockMessagePreviewDisabledByDefault() {
        // Security-conscious default: message content must not appear on the
        // lock screen unless the user explicitly opts in.
        XCTAssertFalse(ChatSettingsViewModel.mock.messagePreviewInNotifications)
    }

    func test_mockReadReceiptsAndTypingIndicatorsEnabled() {
        let m = ChatSettingsViewModel.mock
        XCTAssertTrue(m.readReceiptsEnabled)
        XCTAssertTrue(m.typingIndicatorsEnabled)
    }
}
