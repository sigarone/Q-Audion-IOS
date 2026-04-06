#if canImport(SwiftUI)
import SwiftUI

public struct SecuritySettingsView: View {
    @State private var guardianModeEnabled = true
    @State private var pskEnabled = true
    @State private var redThreshold: Double = 0.5
    @State private var yellowThreshold: Double = 0.8
    @State private var serverUrl = ""
    @State private var proxyEnabled = false

    public init() {}

    public var body: some View {
        Form {
            Section("Guardian Mode") {
                Toggle("Enable Deepfake Detection", isOn: $guardianModeEnabled)
                if guardianModeEnabled {
                    VStack(alignment: .leading) {
                        Text("Red Alert Threshold: \(redThreshold, specifier: "%.2f")")
                        Slider(value: $redThreshold, in: 0...1, step: 0.05)
                    }
                    VStack(alignment: .leading) {
                        Text("Yellow Alert Threshold: \(yellowThreshold, specifier: "%.2f")")
                        Slider(value: $yellowThreshold, in: 0...1, step: 0.05)
                    }
                }
            }

            Section("Pre-Shared Keys") {
                Toggle("Enable PSK", isOn: $pskEnabled)
                NavigationLink("Manage Keys") { KeyManagementView() }
            }

            Section("BCrypto Server") {
                TextField("Server URL", text: $serverUrl)
                    .textContentType(.URL)
                    .autocapitalization(.none)
                Toggle("Use Proxy", isOn: $proxyEnabled)
            }

            Section("Voice Authentication") {
                NavigationLink("Voice Enrollment") { VoiceEnrollmentView() }
            }
        }
        .navigationTitle("Q-Audion Security")
    }
}
#endif
