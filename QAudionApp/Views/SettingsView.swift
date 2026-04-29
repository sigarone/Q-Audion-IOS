import SwiftUI
import QAudionEngine

struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        NavigationStack {
            List {
                Section("Account") {
                    NavigationLink("Profile") { AccountSettingsScreen(appState: appState) }
                    NavigationLink("Security") { SecurityDashboardScreen(state: appState) }
                    NavigationLink("Devices") { DeviceManagementScreen(state: appState) }
                }
                Section("Privacy & Comms") {
                    NavigationLink("Privacy") { PrivacySettingsScreen(state: appState) }
                    NavigationLink("Calls") { CallsSettingsScreen(state: appState) }
                    NavigationLink("Chat") { ChatSettingsScreen(state: appState) }
                    NavigationLink("Notifications") { NotificationsSettingsScreen(state: appState) }
                }
                Section("Storage & Keys") {
                    NavigationLink("Backup") { BackupSettingsScreen(state: appState) }
                    NavigationLink("Key Management") { KeyManagementScreen(state: appState) }
                }
                Section("System") {
                    NavigationLink("Transport") { TransportSettingsScreen(state: appState) }
                    NavigationLink("About") { AboutSettingsScreen(state: appState) }
                    // W22.C: TestFlight-visible entry into the W21+W22
                    // call-screen showcase. Lets the team QA the new
                    // IncomingCall / OutgoingCall / InCall / GroupCall
                    // screens against the Android source + Stitch desktop
                    // ref without touching the production call lifecycle.
                    // Will be removed once the engine exposes sasWords /
                    // keyInfo / transportMode and ContentView routes
                    // active calls through the new InCallScreen instead
                    // of the legacy CallView.
                    NavigationLink("Call Design Showcase") { CallDesignShowcase() }
                }
            }
            .navigationTitle("Settings")
        }
    }
}
