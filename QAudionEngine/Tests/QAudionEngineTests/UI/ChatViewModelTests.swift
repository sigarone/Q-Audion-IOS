import XCTest
@testable import QAudionEngine

final class ChatViewModelTests: XCTestCase {

    func test_mockIsDeterministic() {
        XCTAssertEqual(ChatViewModel.mock, ChatViewModel.mock)
    }

    func test_mockHas3Messages() {
        XCTAssertEqual(ChatViewModel.mock.messages.count, 3)
    }

    func test_mockHasMixedDirections() {
        let outgoing = ChatViewModel.mock.messages.filter { $0.direction == .outgoing }
        let incoming = ChatViewModel.mock.messages.filter { $0.direction == .incoming }
        XCTAssertGreaterThan(outgoing.count, 0)
        XCTAssertGreaterThan(incoming.count, 0)
    }

    func test_mockComposerEmpty() {
        XCTAssertEqual(ChatViewModel.mock.composerText, "")
    }

    func test_mockPeerOnline() {
        XCTAssertTrue(ChatViewModel.mock.isPeerOnline)
    }

    func test_mockNoTypingIndicator() {
        XCTAssertFalse(ChatViewModel.mock.isPeerTyping)
    }

    // MARK: - Group mock tests (§10.3)

    func test_mockGroupHasParticipants() {
        XCTAssertEqual(ChatViewModel.mockGroup.participants?.count, 4)
    }

    func test_mockGroupConversationIsGroupKind() {
        XCTAssertEqual(ChatViewModel.mockGroup.conversation.kind, .group)
    }

    func test_oneToOneMockHasNilParticipants() {
        XCTAssertNil(ChatViewModel.mock.participants)
    }
}
