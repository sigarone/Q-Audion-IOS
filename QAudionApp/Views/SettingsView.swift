import SwiftUI
import QAudionEngine

struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    var body: some View {
        Form {
            Section("Security") {
                SecuritySettingsView()
            }

            Section("Voice") {
                NavigationLink {
                    VoiceEnrollmentView()
                } label: {
                    Label("Voice Enrollment", systemImage: "waveform")
                }
            }

            Section("Keys") {
                NavigationLink {
                    NfcExchangeView()
                } label: {
                    Label("NFC Key Exchange", systemImage: "wave.3.right")
                }
            }

            Section("Account") {
                HStack {
                    Text("User ID")
                    Spacer()
                    Text(appState.userId)
                        .foregroundStyle(.secondary)
                }

                Button(role: .destructive) {
                    appState.logout()
                } label: {
                    Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                }
            }

            Section("About") {
                HStack {
                    Text("App Version")
                    Spacer()
                    Text("\(appVersion) (\(buildNumber))")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("Engine")
                    Spacer()
                    Text("QAudionEngine v1.0")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Settings")
    }
}
