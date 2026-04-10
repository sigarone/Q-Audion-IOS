import SwiftUI
import QAudionEngine

struct HomeView: View {
    @EnvironmentObject var appState: AppState

    @State private var selectedTab = 0
    @State private var contactId = ""

    var body: some View {
        TabView(selection: $selectedTab) {
            // MARK: - Calls Tab
            NavigationStack {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        TextField("Enter contact ID", text: $contactId)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding(10)
                            .background(Color(.secondarySystemBackground))
                            .cornerRadius(8)

                        Button {
                            guard !contactId.isEmpty else { return }
                            appState.startCall(contactId: contactId)
                        } label: {
                            Label("Call", systemImage: "phone.fill")
                                .fontWeight(.semibold)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(contactId.isEmpty)
                    }
                    .padding()

                    List {
                        Section("Recent Calls") {
                            if appState.recentCalls.isEmpty {
                                HStack {
                                    Spacer()
                                    VStack(spacing: 8) {
                                        Image(systemName: "phone.badge.clock")
                                            .font(.title)
                                            .foregroundStyle(.secondary)
                                        Text("No recent calls")
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.vertical, 24)
                                    Spacer()
                                }
                            } else {
                                ForEach(appState.recentCalls, id: \.self) { call in
                                    Label(call, systemImage: "phone.fill")
                                }
                            }
                        }
                    }
                }
                .navigationTitle("Calls")
            }
            .tabItem {
                Label("Calls", systemImage: "phone.fill")
            }
            .tag(0)

            // MARK: - Keys Tab
            NavigationStack {
                KeyManagementView()
            }
            .tabItem {
                Label("Keys", systemImage: "key.fill")
            }
            .tag(1)

            // MARK: - Settings Tab
            NavigationStack {
                SettingsView()
            }
            .tabItem {
                Label("Settings", systemImage: "gear")
            }
            .tag(2)
        }
    }
}
