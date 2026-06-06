import SwiftUI

/// Chat/messaging view for a single conversation.
public struct ChatView: View {
    public let conversationId: String
    public let contactName: String
    @State private var messageText = ""
    @State private var messages: [ChatMessage] = []
    @EnvironmentObject var appState: QAudionAppState

    public init(conversationId: String, contactName: String) {
        self.conversationId = conversationId
        self.contactName = contactName
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Messages
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(messages) { msg in
                        messageBubble(msg)
                    }
                }
                .padding()
            }

            Divider().background(QColors.divider)

            // Input bar
            HStack(spacing: 12) {
                TextField("Messaggio...", text: $messageText)
                    .textFieldStyle(.roundedBorder)

                Button(action: sendMessage) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundColor(messageText.isEmpty ? QColors.textTertiary : QColors.qGreen)
                }
                .disabled(messageText.isEmpty)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(QColors.darkNavy)

            // Call buttons
            HStack(spacing: 24) {
                Button(action: {}) {
                    Label("Audio", systemImage: "phone.fill")
                        .font(.caption)
                }
                Button(action: {}) {
                    Label("Video", systemImage: "video.fill")
                        .font(.caption)
                }
            }
            .padding(.bottom, 4)
            .foregroundColor(QColors.qGreen)
        }
        .background(QColors.deepSpace)
        .navigationTitle(contactName)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func sendMessage() {
        guard !messageText.isEmpty else { return }
        let msgId = UUID().uuidString
        let msg = ChatMessage(id: msgId, text: messageText, isOutgoing: true, timestamp: Date())
        messages.append(msg)
        let text = messageText
        messageText = ""

        // Send via backend
        Task {
            if let msgApi = appState.backend?.messageApi {
                let encrypted = Data(text.utf8) // In production: encrypt with session key
                // Pass msgId so the server echoes it as client_msg_id and
                // the receiver can reconstruct the correct AAD for AEAD.
                _ = try? await msgApi.sendMessage(
                    recipientId: conversationId, content: encrypted, clientMsgId: msgId)
            }
        }
    }

    private func messageBubble(_ msg: ChatMessage) -> some View {
        HStack {
            if msg.isOutgoing { Spacer() }
            VStack(alignment: msg.isOutgoing ? .trailing : .leading, spacing: 4) {
                Text(msg.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(msg.isOutgoing ? QColors.qGreen.opacity(0.2) : QColors.cardSurface)
                    .foregroundColor(QColors.textPrimary)
                    .cornerRadius(16)

                Text(msg.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundColor(QColors.textTertiary)
            }
            if !msg.isOutgoing { Spacer() }
        }
    }
}

public struct ChatMessage: Identifiable {
    public let id: String
    public let text: String
    public let isOutgoing: Bool
    public let timestamp: Date
}
