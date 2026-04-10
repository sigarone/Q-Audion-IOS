import SwiftUI
import QAudionEngine

struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    // MARK: - Deepfake Protection
    @AppStorage("guardianEnabled") private var guardianEnabled = true
    @AppStorage("sensitivity") private var sensitivity: Double = 0.7

    // MARK: - Voice Authentication
    @AppStorage("voiceAuthEnabled") private var voiceAuthEnabled = false
    @AppStorage("voiceEnrolled") private var voiceEnrolled = false

    // MARK: - Pre-Shared Keys
    @AppStorage("pskEnabled") private var pskEnabled = true
    @AppStorage("pskKeyCount") private var pskKeyCount: Int = 3

    // MARK: - NFC Key Exchange
    @AppStorage("nfcEnabled") private var nfcEnabled = false
    @AppStorage("lastNfcSync") private var lastNfcSync: Double = 0

    // MARK: - Advanced
    @AppStorage("waveformVisualization") private var waveformVisualization = true
    @AppStorage("voiceAnalysis") private var voiceAnalysis = false

    // MARK: - BCrypto Server
    @AppStorage("authMode") private var authMode: String = "linked"
    @State private var isTesting = false

    // MARK: - Privacy & Anonymization
    @AppStorage("proxyEnabled") private var proxyEnabled = false
    @AppStorage("proxyHost") private var proxyHost: String = ""
    @AppStorage("proxyPort") private var proxyPort: String = ""
    @AppStorage("proxyType") private var proxyType: String = "HTTP"
    @AppStorage("forceRelayMode") private var forceRelayMode = false

    // MARK: - Computed helpers

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    private var connectionColor: Color {
        switch appState.connectionStatus {
        case "connected": return .green
        case "error": return .red
        default: return .gray
        }
    }

    private var connectionLabel: String {
        switch appState.connectionStatus {
        case "connected": return "Connected"
        case "connecting": return "Connecting..."
        case "error": return "Error"
        default: return "Not configured"
        }
    }

    private var lastSyncText: String? {
        guard lastNfcSync > 0 else { return nil }
        let date = Date(timeIntervalSince1970: lastNfcSync)
        let elapsed = Date().timeIntervalSince(date)
        if elapsed < 3600 {
            let minutes = Int(elapsed / 60)
            return "Last sync: \(minutes) min ago"
        } else if elapsed < 86400 {
            let hours = Int(elapsed / 3600)
            return "Last sync: \(hours) hours ago"
        } else {
            let days = Int(elapsed / 86400)
            return "Last sync: \(days) days ago"
        }
    }

    // MARK: - Body

    var body: some View {
        Form {
            deepfakeProtectionSection
            voiceAuthSection
            preSharedKeysSection
            nfcSection
            advancedSection
            bcryptoServerSection
            privacySection
            accountSection
            aboutSection
        }
        .navigationTitle("Q-Audion Security")
    }

    // MARK: - Deepfake Protection

    private var deepfakeProtectionSection: some View {
        Section {
            Toggle(isOn: $guardianEnabled) {
                Label("Guardian Mode", systemImage: "shield.checkered")
            }

            if guardianEnabled {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Sensitivity")
                        Spacer()
                        Text("\(Int(sensitivity * 100))%")
                            .foregroundStyle(.secondary)
                            .font(.subheadline)
                    }
                    Slider(value: $sensitivity, in: 0.0...1.0, step: 0.05)
                }
            }

            Text("Real-time detection during calls")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Label("Deepfake Protection", systemImage: "exclamationmark.shield.fill")
        }
    }

    // MARK: - Voice Authentication

    private var voiceAuthSection: some View {
        Section {
            Toggle(isOn: $voiceAuthEnabled) {
                Label("Voice Auth", systemImage: "person.wave.2.fill")
            }

            NavigationLink {
                VoiceEnrollmentView()
            } label: {
                HStack {
                    Label("Enroll Voice", systemImage: "waveform")
                    Spacer()
                    if voiceEnrolled {
                        Text("Enrolled \u{2713}")
                            .font(.subheadline)
                            .foregroundStyle(.green)
                    } else {
                        Text("Not enrolled")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Label("Voice Authentication", systemImage: "mic.badge.shield.fill")
        }
    }

    // MARK: - Pre-Shared Keys

    private var preSharedKeysSection: some View {
        Section {
            Toggle(isOn: $pskEnabled) {
                Label("Enable PSK", systemImage: "key.fill")
            }

            NavigationLink {
                KeyManagementView()
            } label: {
                HStack {
                    Label("Manage Keys", systemImage: "key.viewfinder")
                    Spacer()
                    Text("\(pskKeyCount) keys")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Text("Defense-in-depth: PSK mixed via HKDF")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Label("Pre-Shared Keys", systemImage: "lock.shield.fill")
        }
    }

    // MARK: - NFC Key Exchange

    private var nfcSection: some View {
        Section {
            Toggle(isOn: $nfcEnabled) {
                Label("NFC Exchange", systemImage: "wave.3.right")
            }

            NavigationLink {
                NfcExchangeView()
            } label: {
                Label("Exchange Keys", systemImage: "wave.3.right.circle")
            }

            if let syncText = lastSyncText {
                Text(syncText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Label("NFC Key Exchange", systemImage: "antenna.radiowaves.left.and.right")
        }
    }

    // MARK: - Advanced

    private var advancedSection: some View {
        Section {
            Toggle(isOn: $waveformVisualization) {
                Label("Waveform Visualization", systemImage: "waveform.path.ecg")
            }

            Toggle(isOn: $voiceAnalysis) {
                Label("Voice Analysis", systemImage: "chart.bar.xaxis.ascending")
            }

            HStack {
                Text("QAudionEngine v1.0")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Label("Advanced", systemImage: "gearshape.2.fill")
        }
    }

    // MARK: - BCrypto Server

    private var bcryptoServerSection: some View {
        Section {
            TextField("Server URL", text: $appState.serverUrl)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)

            HStack {
                Label("Connection", systemImage: "network")
                Spacer()
                Circle()
                    .fill(connectionColor)
                    .frame(width: 10, height: 10)
                Text(connectionLabel)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Picker("Backend Mode", selection: $appState.backendMode) {
                Text("Signal").tag("signal_only")
                Text("Dual").tag("dual")
                Text("BCrypto").tag("bcrypto_only")
            }
            .pickerStyle(.segmented)

            Button {
                isTesting = true
                Task {
                    await appState.testConnection()
                    isTesting = false
                }
            } label: {
                HStack {
                    Label("Test Connection", systemImage: "bolt.horizontal.fill")
                    if isTesting {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(isTesting || appState.serverUrl.isEmpty)

            Picker("Auth Mode", selection: $authMode) {
                Text("Linked").tag("linked")
                Text("Independent").tag("independent")
            }
            .pickerStyle(.segmented)

            if appState.isAuthenticated, let userId = appState.currentUserId {
                HStack {
                    Label("Logged in as", systemImage: "person.crop.circle.badge.checkmark")
                        .font(.subheadline)
                    Spacer()
                    Text(userId)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Button(role: .destructive) {
                    appState.logout()
                } label: {
                    Label("Logout", systemImage: "rectangle.portrait.and.arrow.right")
                }
            } else {
                HStack(spacing: 12) {
                    NavigationLink {
                        LoginView()
                    } label: {
                        Text("Login")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    NavigationLink {
                        RegisterView()
                    } label: {
                        Text("Register")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
        } header: {
            Label("BCrypto Server", systemImage: "server.rack")
        }
    }

    // MARK: - Privacy & Anonymization

    private var privacySection: some View {
        Section {
            Toggle(isOn: $proxyEnabled) {
                Label("Enable Proxy", systemImage: "network.badge.shield.half.filled")
            }

            if proxyEnabled {
                TextField("Proxy Host", text: $proxyHost)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                TextField("Proxy Port", text: $proxyPort)
                    .keyboardType(.numberPad)

                Picker("Proxy Type", selection: $proxyType) {
                    Text("HTTP").tag("HTTP")
                    Text("SOCKS5").tag("SOCKS5")
                }
            }

            Toggle(isOn: $forceRelayMode) {
                Label("Force Relay Mode", systemImage: "arrow.triangle.branch")
            }

            if forceRelayMode {
                Text("Route all media through relay to hide IP")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Label("Privacy & Anonymization", systemImage: "eye.slash.fill")
        }
    }

    // MARK: - Account

    private var accountSection: some View {
        Section {
            HStack {
                Label("User ID", systemImage: "person.text.rectangle")
                Spacer()
                Text(appState.currentUserId ?? "Not signed in")
                    .foregroundStyle(.secondary)
            }

            Button(role: .destructive) {
                appState.logout()
            } label: {
                Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
            }
        } header: {
            Label("Account", systemImage: "person.crop.circle")
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section {
            HStack {
                Label("App Version", systemImage: "info.circle")
                Spacer()
                Text(appVersion)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Label("Engine", systemImage: "cpu")
                Spacer()
                Text("QAudionEngine v1.0")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Label("About", systemImage: "questionmark.circle")
        }
    }
}
