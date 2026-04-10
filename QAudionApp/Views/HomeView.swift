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
                    HStack(spacing: 8) {
                        TextField("Enter contact ID", text: $contactId)
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
