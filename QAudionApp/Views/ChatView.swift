import SwiftUI
import QAudionEngine

struct ChatView: View {
    @EnvironmentObject var appState: AppState
    let conversationId: String
    let contactName: String

    @State private var messageText = ""
    @State private var scrollToBottom = false

    var body: some View {
        VStack(spacing: 0) {
            // MARK: - Encryption Banner
            encryptionBanner

            // MARK: - Messages List
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(appState.currentMessages) { message in
                            MessageBubbleView(
                                isSent: message.isSent,
                                text: message.text,
                                timestamp: message.timestamp,
                                isEncrypted: message.isEncrypted
                            )
                            .id(message.id)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .onChange(of: appState.currentMessages.count) { _ in
                    scrollToLastMessage(proxy: proxy)
                }
                .onAppear {
                    scrollToLastMessage(proxy: proxy)
                }
            }

            // MARK: - Input Bar
            inputBar
        }
        .background(Color(white: 0.06))
        .navigationTitle(contactName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(content: {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                    Text(contactName)
                        .font(.headline)
                        .foregroundStyle(.white)
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    Task { await appState.startCall(contactId: conversationId, video: false) }
                } label: {
                    Image(systemName: "phone.fill")
                        .foregroundStyle(.cyan)
                }
            }
        })
        .task {
            await appState.loadMessages(for: conversationId)
        }
    }

    // MARK: - Encryption Banner

    private var encryptionBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.shield.fill")
                .font(.caption2)
            Text("End-to-end encrypted")
                .font(.caption2)
                .fontWeight(.medium)
        }
        .foregroundStyle(.green.opacity(0.8))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(Color.green.opacity(0.08))
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField("Message", text: $messageText)
                .textFieldStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(white: 0.14))
                .cornerRadius(20)
                .foregroundStyle(.white)
                .lineLimit(5)

            Button {
                sendMessage()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(messageText.trimmingCharacters(in: .whitespaces).isEmpty ? .gray : .cyan)
            }
            .disabled(messageText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(white: 0.10))
    }

    // MARK: - Actions

    private func sendMessage() {
        let text = messageText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        messageText = ""
        Task {
            await appState.sendMessage(to: conversationId, text: text)
        }
    }

    private func scrollToLastMessage(proxy: ScrollViewProxy) {
        guard let lastId = appState.currentMessages.last?.id else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(lastId, anchor: .bottom)
        }
    }
}
