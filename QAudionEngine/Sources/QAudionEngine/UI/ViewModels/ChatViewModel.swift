import Foundation

public struct ChatViewModel: ViewModelProtocol {

    // MARK: - Participant

    public struct Participant: Equatable, Sendable, Hashable {
        public let userId: String
        public let displayName: String
        public let isAdmin: Bool

        public init(userId: String, displayName: String, isAdmin: Bool) {
            self.userId = userId
            self.displayName = displayName
            self.isAdmin = isAdmin
        }
    }

    // MARK: - Properties

    public let conversation: Conversation
    public let messages: [Message]
    public let composerText: String
    public let isPeerTyping: Bool
    public let isPeerOnline: Bool
    /// Non-nil for group conversations; nil for 1:1.
    public let participants: [Participant]?

    public init(conversation: Conversation, messages: [Message],
                composerText: String = "", isPeerTyping: Bool = false,
                isPeerOnline: Bool = false, participants: [Participant]? = nil) {
        self.conversation = conversation
        self.messages = messages
        self.composerText = composerText
        self.isPeerTyping = isPeerTyping
        self.isPeerOnline = isPeerOnline
        self.participants = participants
    }

    // MARK: - Mocks

    // force-unwraps below (mock/mockGroup) are safe: fixed hardcoded UUID
    // string literals ("1111...", "2222..."), well-formed by inspection —
    // not user/network input, so UUID(uuidString:) can never return nil here.
    public static let mock = ChatViewModel(
        conversation: Conversation(
            // swiftlint:disable:next force_unwrapping
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            peerUserId: "user-alice",
            peerDisplayName: "Alice (Pixel 7)",
            lastMessagePreview: "See you soon",
            lastActivity: Date(timeIntervalSince1970: 1_745_000_000),
            unreadCount: 0,
            pinned: false
        ),
        messages: [
            // swiftlint:disable:next force_unwrapping
            Message(id: UUID(), conversationId: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                    direction: .outgoing, plaintext: "Ciao Alice",
                    sentAt: Date(timeIntervalSince1970: 1_744_999_500),
                    deliveredAt: Date(timeIntervalSince1970: 1_744_999_510),
                    readAt: Date(timeIntervalSince1970: 1_744_999_550),
                    status: .read),
            // swiftlint:disable:next force_unwrapping
            Message(id: UUID(), conversationId: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                    direction: .incoming, plaintext: "Ciao! Come va?",
                    sentAt: Date(timeIntervalSince1970: 1_744_999_600),
                    deliveredAt: Date(timeIntervalSince1970: 1_744_999_605),
                    readAt: Date(timeIntervalSince1970: 1_744_999_650),
                    status: .read),
            // swiftlint:disable:next force_unwrapping
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

    public static let mockGroup = ChatViewModel(
        conversation: Conversation(
            // swiftlint:disable:next force_unwrapping
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            peerUserId: "group-design-team",
            peerDisplayName: "Design team",
            lastMessagePreview: "See you on Friday",
            lastActivity: Date(timeIntervalSince1970: 1_745_001_000),
            unreadCount: 2,
            pinned: true,
            kind: .group
        ),
        messages: [
            // swiftlint:disable:next force_unwrapping
            Message(id: UUID(), conversationId: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                    direction: .incoming, plaintext: "Anyone reviewed the wireframes?",
                    sentAt: Date(timeIntervalSince1970: 1_745_000_500),
                    deliveredAt: Date(timeIntervalSince1970: 1_745_000_510),
                    readAt: nil, status: .delivered, senderUserId: "user-bob"),
            // swiftlint:disable:next force_unwrapping
            Message(id: UUID(), conversationId: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                    direction: .incoming, plaintext: "Looks good. Ship it.",
                    sentAt: Date(timeIntervalSince1970: 1_745_000_700),
                    deliveredAt: Date(timeIntervalSince1970: 1_745_000_710),
                    readAt: nil, status: .delivered, senderUserId: "user-charlie")
        ],
        composerText: "",
        isPeerTyping: false,
        isPeerOnline: true,
        participants: [
            Participant(userId: "user-self", displayName: "You", isAdmin: true),
            Participant(userId: "user-alice", displayName: "Alice", isAdmin: false),
            Participant(userId: "user-bob", displayName: "Bob", isAdmin: false),
            Participant(userId: "user-charlie", displayName: "Charlie", isAdmin: false)
        ]
    )
}
