import SwiftUI
import QAudionEngine

struct HomeView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.qaudionScheme) private var scheme
    @State private var selectedTab: Tab = .chats
    @State private var presentingInCall: Bool = false

    enum Tab: Hashable {
        case chats
        case contacts
        case calls
        case settings
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            chatsTab
                .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right.fill") }
                .tag(Tab.chats)

            contactsTab
                .tabItem { Label("Contatti", systemImage: "person.2.fill") }
                .tag(Tab.contacts)

            callsTab
                .tabItem { Label("Chiamate", systemImage: "phone.fill") }
                .tag(Tab.calls)

            settingsTab
                .tabItem { Label("Impostazioni", systemImage: "gearshape.fill") }
                .tag(Tab.settings)
        }
        // W32: tint del tab bar (icona + label selezionati) sul primary
        // del design system Q-Audion. La tab non-selezionata mantiene
        // il default UIKit (grigio iOS) per leggibilità.
        .tint(scheme.primary)
        .overlay(alignment: .top) {
            if appState.isInCall && !presentingInCall {
                inCallBanner
            }
        }
        .fullScreenCover(isPresented: $presentingInCall) {
            inCallCoverView
        }
        .onChange(of: appState.isInCall) { isInCall in
            // Single-param form for iOS 16 compat. Auto-dismiss the cover
            // when the call ends.
            if !isInCall {
                presentingInCall = false
            }
        }
    }

    // MARK: - Tabs

    private var chatsTab: some View {
        // W19.G: replaced the bare `ConversationListView()` with the
        // sectioned `ChatListScreen` — admin banner / Gruppi / Fissate /
        // Conversazioni + 2 FABs, 1:1 visual port of Android
        // `qaudion-android-new/feature/feature-chat/.../ChatListScreen.kt`.
        // Data layer (`ConversationListContainer`) is unchanged: only the
        // presentation layer flipped, so the existing chat / search /
        // pin / delete / new-conversation flows keep working.
        NavigationStack {
            ChatListScreen()
        }
    }

    private var contactsTab: some View {
        // W23: Tab Contatti ora usa il nuovo `ContactsScreen` (1:1 visual
        // port di Android `feature-contacts/.../ContactsScreen.kt`) con
        // tab TUTTI / SCOPRI / BLOCCATI, ricerca capsule, FAB
        // person.badge.plus, ContactDetailScreen con TrustVerificationCard
        // / MetadataCard / SecurityLog. Il legacy `ContactsListView`
        // resta ancora montato per i flow di scan/import (sheets) finché
        // non li portiamo alla nuova UI.
        NavigationStack {
            ContactsScreen()
        }
    }

    /// Calls tab: quick-dial + recent calls list, matching the old HomeView's Calls tab content.
    private var callsTab: some View {
        NavigationStack {
            CallsTabView()
                .navigationTitle("Chiamate")
        }
    }

    /// W24: Settings tab usa il nuovo `SettingsScreen` (1:1 visual port di
    /// Android `feature-settings/.../SettingsScreen.kt`) con
    /// ProfileHeroCard + SecurityChipsRow + sezioni ACCOUNT / SICUREZZA /
    /// PRIVACY / DATI / INFO / SVILUPPATORE. Le 11 sub-screen esistenti
    /// (AccountSettings / Privacy / Calls / Chat / Notifications / Backup
    /// / KeyManagement / Transport / About / Security / DeviceManagement)
    /// restano invariate — sono raggiunte via NavigationLink dal nuovo
    /// root. Toggle interni (DeepfakeGuard, ReadReceipts, etc.) restano
    /// nelle rispettive sub-screen finché l'engine non espone una
    /// SettingsUiState unificata.
    private var settingsTab: some View {
        SettingsScreen()
    }

    // MARK: - Active call banner

    private var inCallBanner: some View {
        Button(action: { presentingInCall = true }) {
            HStack {
                Image(systemName: "phone.fill")
                Text(appState.callContactId.map { "Chiamata attiva con \($0)" } ?? "Chiamata attiva")
                Spacer()
                Text("Tocca per rientrare")
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 16).padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(Color.green)
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Full-screen in-call cover

    @ViewBuilder
    private var inCallCoverView: some View {
        if appState.activeCallKitId != nil {
            // Present the W12.D CallView (which internally creates InCallContainer
            // and delegates to InCallView). Interactive dismiss is disabled so the
            // user cannot accidentally swipe away mid-call; they must use the
            // in-call hang-up button, after which isInCall → false triggers the
            // onChange above and dismisses the cover.
            NavigationStack {
                CallView()
            }
            .environmentObject(appState)
            .interactiveDismissDisabled(true)
        } else {
            // Fallback: activeCallKitId not yet populated (race during call setup).
            // Show a minimal state and let the user dismiss manually.
            VStack(spacing: 24) {
                Image(systemName: "phone.down.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("Nessuna chiamata attiva")
                    .font(.title2.weight(.semibold))
                Button("Chiudi") { presentingInCall = false }
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Calls tab content (preserved from original HomeView)

private struct CallsTabView: View {
    @EnvironmentObject var appState: AppState
    @State private var contactId = ""

    var body: some View {
        VStack(spacing: 0) {
            // Quick-dial bar
            HStack(spacing: 8) {
                TextField("Inserisci ID contatto", text: $contactId)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(10)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(8)

                Button {
                    guard !contactId.isEmpty else { return }
                    Task { await appState.startCall(contactId: contactId, video: false) }
                } label: {
                    Image(systemName: "phone.fill")
                        .font(.body)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .disabled(contactId.isEmpty)

                Button {
                    guard !contactId.isEmpty else { return }
                    Task { await appState.startCall(contactId: contactId, video: true) }
                } label: {
                    Image(systemName: "video.fill")
                        .font(.body)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(contactId.isEmpty)
            }
            .padding()

            List {
                Section("Chiamate recenti") {
                    if appState.recentCalls.isEmpty {
                        HStack {
                            Spacer()
                            VStack(spacing: 8) {
                                Image(systemName: "phone.badge.checkmark")
                                    .font(.title)
                                    .foregroundStyle(.secondary)
                                Text("Nessuna chiamata recente")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Text("Lo storico apparirà qui dopo la prima chiamata.")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .multilineTextAlignment(.center)
                            }
                            .padding(.vertical, 24)
                            Spacer()
                        }
                    } else {
                        ForEach(appState.recentCalls, id: \.self) { call in
                            HStack {
                                Label(call, systemImage: "phone.fill")
                                Spacer()
                                Button {
                                    Task { await appState.startCall(contactId: call, video: false) }
                                } label: {
                                    Image(systemName: "phone.fill")
                                        .foregroundStyle(.blue)
                                }
                                .buttonStyle(.plain)

                                Button {
                                    Task { await appState.startCall(contactId: call, video: true) }
                                } label: {
                                    Image(systemName: "video.fill")
                                        .foregroundStyle(.green)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Contacts tab placeholder

private struct ContactsTabPlaceholder: View {
    var body: some View {
        if #available(iOS 17.0, *) {
            ContentUnavailableView {
                Label("Contacts", systemImage: "person.2.fill")
            } description: {
                Text("Add a contact via NFC pairing or QR code in Settings → Key Management.")
            }
        } else {
            VStack(spacing: 16) {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("Contacts")
                    .font(.title2.weight(.semibold))
                Text("Add a contact via NFC pairing or QR code in Settings → Key Management.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
