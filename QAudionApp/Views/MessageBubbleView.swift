import SwiftUI
import QAudionEngine

struct MessageBubbleView: View {
    let message: Message
    let isGroup: Bool
    let senderName: String?

    // MARK: - Back-compat init for callers that don't yet use the Message model.

    init(isSent: Bool, text: String, timestamp: Date, isEncrypted: Bool = true) {
        self.message = Message(
            id: UUID(),
            conversationId: UUID(),
            direction: isSent ? .outgoing : .incoming,
            plaintext: text,
            sentAt: timestamp,
            deliveredAt: isSent ? timestamp : nil,
            readAt: nil,
            status: isSent ? .sent : .delivered
        )
        self.isGroup = false
        self.senderName = nil
    }

    /// Primary init: full Message model (W11.A path).
    init(message: Message) {
        self.message = message
        self.isGroup = false
        self.senderName = nil
    }

    /// Group-aware init: used by ChatView for group conversations.
    init(message: Message, isGroup: Bool, senderName: String?) {
        self.message = message
        self.isGroup = isGroup
        self.senderName = senderName
    }

    // MARK: - Body

    var body: some View {
        HStack {
            if message.direction == .outgoing { Spacer(minLength: 48) }
            bubbleContent
            if message.direction == .incoming { Spacer(minLength: 48) }
        }
    }

    private var bubbleContent: some View {
        VStack(alignment: message.direction == .outgoing ? .trailing : .leading, spacing: 4) {
            if isGroup, message.direction == .incoming, let name = senderName {
                Text(name)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.cyan.opacity(0.85))
                    .padding(.horizontal, 4)
            }
            Text(message.plaintext)
                .font(.body)
                .foregroundStyle(textColor)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(bubbleColor)
                .clipShape(RoundedRectangle(cornerRadius: 16))

            HStack(spacing: 4) {
                // Encrypted-lock indicator (always shown — this app is e2e encrypted).
                Image(systemName: "lock.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.5))

                Text(message.sentAt, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.5))

                if message.direction == .outgoing {
                    statusIcon
                }
            }
        }
    }

    private var bubbleColor: Color {
        message.direction == .outgoing ? .blue : Color(white: 0.18)
    }

    private var textColor: Color {
        .white
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch message.status {
        case .sending:
            Image(systemName: "clock")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.5))
        case .sent:
            Image(systemName: "checkmark")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.5))
        case .delivered:
            Image(systemName: "checkmark.circle")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.5))
        case .read:
            Image(systemName: "checkmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.cyan)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(.red)
        }
    }
}
