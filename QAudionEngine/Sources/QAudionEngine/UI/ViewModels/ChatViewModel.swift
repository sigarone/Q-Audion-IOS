import Foundation

public struct ChatViewModel: ViewModelProtocol {

    public let conversation: Conversation
    public let messages: [Message]
    public let composerText: String
    public let isPeerTyping: Bool
    public let isPeerOnline: Bool

    public init(conversation: Conversation, messages: [Message],
                composerText: String = "", isPeerTyping: Bool = false,
                isPeerOnline: Bool = false) {
        self.conversation = conversation
        self.messages = messages
        self.composerText = composerText
        self.isPeerTyping = isPeerTyping
        self.isPeerOnline = isPeerOnline
    }

    public static let mock = ChatViewModel(
        conversation: Conversation(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            peerUserId: "user-alice",
            peerDisplayName: "Alice (Pixel 7)",
            lastMessagePreview: "See you soon",
            lastActivity: Date(timeIntervalSince1970: 1_745_000_000),
            unreadCount: 0,
            pinned: false
        ),
        messages: [
            Message(id: UUID(), conversationId: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                    direction: .outgoing, plaintext: "Ciao Alice",
                    sentAt: Date(timeIntervalSince1970: 1_744_999_500),
                    deliveredAt: Date(timeIntervalSince1970: 1_744_999_510),
                    readAt: Date(timeIntervalSince1970: 1_744_999_550),
                    status: .read),
            Message(id: UUID(), conversationId: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                    direction: .incoming, plaintext: "Ciao! Come va?",
                    sentAt: Date(timeIntervalSince1970: 1_744_999_600),
                    deliveredAt: Date(timeIntervalSince1970: 1_744_999_605),
                    readAt: Date(timeIntervalSince1970: 1_744_999_650),
                    status: .read),
            Message(id: UUID(), conversationId: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                    direction: .outgoing, plaintext: "Tutto bene, grazie. Ci vediamo alle 18?",
                    sentAt: Date(timeIntervalSince1970: 1_744_999_700),
                    deliveredAt: Date(timeIntervalSince1970: 1_744_999_710),
                    readAt: nil,
                    status: .delivered)
        ],
        composerText: "",
        isPeerTyping: false,
        isPeerOnline: true
    )
}
