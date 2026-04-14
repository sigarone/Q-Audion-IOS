import SwiftUI

/// Main tab screen matching Android QAudionMainScreen.
/// Tabs: Chat, Chiamate, Contatti, Sicurezza
public struct QAudionMainView: View {
    @State private var selectedTab = 0
    @EnvironmentObject var appState: QAudionAppState

    public init() {}

    public var body: some View {
        TabView(selection: $selectedTab) {
            ConversationListView()
                .tabItem {
                    Label("Chat", systemImage: "message.fill")
                }
                .tag(0)
                .badge(appState.totalUnread)

            CallHistoryView()
                .tabItem {
                    Label("Chiamate", systemImage: "phone.fill")
                }
                .tag(1)

            ContactsListView()
                .tabItem {
                    Label("Contatti", systemImage: "person.2.fill")
                }
                .tag(2)

            SecurityDashboardView()
                .tabItem {
                    Label("Sicurezza", systemImage: "shield.fill")
                }
                .tag(3)
        }
        .tint(QColors.qGreen)
        .qAudionTheme()
    }
}

// MARK: - Conversation List

public struct ConversationListView: View {
    @EnvironmentObject var appState: QAudionAppState

    public init() {}

    public var body: some View {
        NavigationStack {
            Group {
                if appState.conversations.isEmpty {
                    emptyState(icon: "message.fill", message: "Nessuna conversazione", hint: "Tocca + per iniziare una nuova chat")
                } else {
                    List(appState.conversations) { conv in
                        NavigationLink(destination: ChatView(conversationId: conv.id, contactName: conv.contactName)) {
                            conversationRow(conv)
                        }
                        .listRowBackground(QColors.deepSpace)
                    }
                    .listStyle(.plain)
                }
            }
            .background(QColors.deepSpace)
            .navigationTitle("Q-Audion")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: { appState.showContactDiscovery = true }) {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $appState.showContactDiscovery) {
                ContactDiscoveryView()
            }
        }
    }

    private func conversationRow(_ item: ConversationItem) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(QColors.cardSurface)
                .frame(width: 48, height: 48)
                .overlay(
                    Text(String(item.contactName.prefix(1)).uppercased())
                        .font(.headline)
                        .foregroundColor(QColors.textPrimary)
                )

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(item.contactName)
                        .font(.body)
                        .fontWeight(item.unreadCount > 0 ? .bold : .regular)
                        .foregroundColor(QColors.textPrimary)
                    TrustShieldView(trustLevel: item.trustLevel, compact: true)
                    Spacer()
                    Text(item.timestamp)
                        .font(.caption2)
                        .foregroundColor(item.unreadCount > 0 ? QColors.qGreen : QColors.textTertiary)
                }
                HStack {
                    Text(item.lastMessage)
                        .font(.subheadline)
                        .foregroundColor(item.unreadCount > 0 ? QColors.textPrimary : QColors.textSecondary)
                        .lineLimit(1)
                    Spacer()
                    if item.unreadCount > 0 {
                        Text("\(item.unreadCount)")
                            .font(.caption2.bold())
                            .foregroundColor(QColors.textOnPrimary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(QColors.qGreen)
                            .clipShape(Capsule())
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Call History

public struct CallHistoryView: View {
    @EnvironmentObject var appState: QAudionAppState

    public init() {}

    public var body: some View {
        NavigationStack {
            Group {
                if appState.callHistory.isEmpty {
                    emptyState(icon: "phone.fill", message: "Nessuna chiamata", hint: "Le tue chiamate appariranno qui")
                } else {
                    List(appState.callHistory) { call in
                        callRow(call)
                            .listRowBackground(QColors.deepSpace)
                    }
                    .listStyle(.plain)
                }
            }
            .background(QColors.deepSpace)
            .navigationTitle("Chiamate")
        }
    }

    private func callRow(_ item: CallHistoryItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.isVideo ? "video.fill" : "phone.fill")
                .foregroundColor(item.isMissed ? QColors.error : (item.isIncoming ? QColors.qBlue : QColors.qGreen))

            VStack(alignment: .leading) {
                HStack {
                    Text(item.contactName)
                        .foregroundColor(item.isMissed ? QColors.error : QColors.textPrimary)
                        .fontWeight(.medium)
                    TrustShieldView(trustLevel: item.trustLevel, compact: true)
                }
                Text("\(item.isIncoming ? "Ricevuta" : "Effettuata")\(item.isVideo ? " (video)" : "")")
                    .font(.caption)
                    .foregroundColor(QColors.textSecondary)
            }

            Spacer()

            Text(item.timestamp)
                .font(.caption2)
                .foregroundColor(QColors.textTertiary)
        }
    }
}

// MARK: - Contacts List

public struct ContactsListView: View {
    @EnvironmentObject var appState: QAudionAppState

    public init() {}

    public var body: some View {
        NavigationStack {
            Group {
                if appState.contacts.isEmpty {
                    emptyState(icon: "person.2.fill", message: "Nessun contatto", hint: "Aggiungi contatti tramite QR code o link")
                } else {
                    List(appState.contacts) { contact in
                        NavigationLink(destination: ContactDetailView(
                            contact: DiscoveredContact(userId: contact.id, phoneHash: "", displayName: contact.displayName),
                            trustLevel: contact.trustLevel
                        )) {
                            contactRow(contact)
                        }
                        .listRowBackground(QColors.deepSpace)
                    }
                    .listStyle(.plain)
                }
            }
            .background(QColors.deepSpace)
            .navigationTitle("Contatti")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: { appState.showContactDiscovery = true }) {
                        Image(systemName: "person.badge.plus")
                    }
                }
            }
        }
    }

    private func contactRow(_ item: ContactItem) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(QColors.cardSurface)
                .frame(width: 44, height: 44)
                .overlay(
                    Text(String(item.displayName.prefix(1)).uppercased())
                        .foregroundColor(QColors.textPrimary)
                )

            VStack(alignment: .leading) {
                Text(item.displayName)
                    .foregroundColor(QColors.textPrimary)
                    .fontWeight(.medium)
                if !item.lastSeen.isEmpty {
                    Text("Ultimo accesso: \(item.lastSeen)")
                        .font(.caption2)
                        .foregroundColor(QColors.textTertiary)
                }
            }

            Spacer()

            TrustShieldView(trustLevel: item.trustLevel, compact: true)
        }
    }
}

// MARK: - Data Models (matching Android)

public struct ConversationItem: Identifiable {
    public let id: String
    public let contactName: String
    public let lastMessage: String
    public let timestamp: String
    public let unreadCount: Int
    public let trustLevel: TrustShieldView.TrustLevel
    public let isQAudionBackend: Bool

    public init(id: String, contactName: String, lastMessage: String, timestamp: String,
                unreadCount: Int = 0, trustLevel: TrustShieldView.TrustLevel = .unknown, isQAudionBackend: Bool = true) {
        self.id = id; self.contactName = contactName; self.lastMessage = lastMessage
        self.timestamp = timestamp; self.unreadCount = unreadCount
        self.trustLevel = trustLevel; self.isQAudionBackend = isQAudionBackend
    }
}

public struct CallHistoryItem: Identifiable {
    public let id: String
    public let contactName: String
    public let timestamp: String
    public let isIncoming: Bool
    public let isMissed: Bool
    public let isVideo: Bool
    public let trustLevel: TrustShieldView.TrustLevel

    public init(id: String, contactName: String, timestamp: String, isIncoming: Bool,
                isMissed: Bool = false, isVideo: Bool = false, trustLevel: TrustShieldView.TrustLevel = .unknown) {
        self.id = id; self.contactName = contactName; self.timestamp = timestamp
        self.isIncoming = isIncoming; self.isMissed = isMissed; self.isVideo = isVideo; self.trustLevel = trustLevel
    }
}

public struct ContactItem: Identifiable {
    public let id: String
    public let displayName: String
    public let trustLevel: TrustShieldView.TrustLevel
    public let lastSeen: String

    public init(id: String, displayName: String, trustLevel: TrustShieldView.TrustLevel = .unknown, lastSeen: String = "") {
        self.id = id; self.displayName = displayName; self.trustLevel = trustLevel; self.lastSeen = lastSeen
    }
}

// MARK: - Empty State Helper

private func emptyState(icon: String, message: String, hint: String) -> some View {
    VStack(spacing: 16) {
        Spacer()
        Image(systemName: icon)
            .font(.system(size: 64))
            .foregroundColor(QColors.textTertiary)
        Text(message)
            .font(.title3)
            .foregroundColor(QColors.textSecondary)
        Text(hint)
            .font(.subheadline)
            .foregroundColor(QColors.textTertiary)
        Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
}
