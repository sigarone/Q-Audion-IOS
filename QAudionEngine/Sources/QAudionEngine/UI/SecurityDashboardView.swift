import SwiftUI

/// Security Dashboard matching Android's SecurityDashboardScreen.
/// Shows real-time crypto status, threat alerts, and compliance info.
public struct SecurityDashboardView: View {
    @State private var compliance = CryptoComplianceInfo.checkDeviceCompliance()
    @State private var threatCount: Int = 0
    @State private var sessionActive: Bool = false
    @State private var pqcEnabled: Bool = CryptoConstants.hybridPqcEnabled
    @State private var fipsMode: Bool = CryptoConstants.fipsMode
    @State private var secureEnclaveAvailable: Bool = false

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Header
                HStack {
                    Image(systemName: compliance.isCompliant ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                        .font(.title)
                        .foregroundColor(compliance.isCompliant ? .green : .red)
                    VStack(alignment: .leading) {
                        Text("Security Status")
                            .font(.headline)
                        Text(compliance.isCompliant ? "Fully Compliant" : "Issues Detected")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(12)

                // Crypto Stack
                sectionCard(title: "Cryptographic Stack") {
                    statusRow("PQC", CryptoComplianceInfo.pqcStandard, .green)
                    statusRow("AEAD", CryptoComplianceInfo.aeadStandard, .green)
                    statusRow("KDF", CryptoComplianceInfo.kdfStandard, .green)
                    statusRow("KEX", CryptoComplianceInfo.hybridKex, .green)
                    statusRow("Module", CryptoComplianceInfo.cryptoModule, .green)
                }

                // Hardware Security
                sectionCard(title: "Hardware Security") {
                    statusRow("Secure Enclave", compliance.hasSecureEnclave ? "Available" : "Not Available",
                             compliance.hasSecureEnclave ? .green : .orange)
                    statusRow("FIPS 140-3", fipsMode ? "Enabled" : "Disabled",
                             fipsMode ? .green : .red)
                    statusRow("Hybrid PQC", pqcEnabled ? "Enabled" : "Disabled",
                             pqcEnabled ? .green : .red)
                }

                // Session Info
                sectionCard(title: "Active Session") {
                    statusRow("Status", sessionActive ? "Encrypted" : "No Active Session",
                             sessionActive ? .green : .gray)
                    statusRow("Forward Secrecy", "X25519 DH Ratchet", .green)
                    statusRow("Ratchet Interval", "\(CryptoConstants.ratchetIntervalFrames) frames", .blue)
                }

                // Threat Detection
                sectionCard(title: "Threat Detection") {
                    statusRow("Replay Window", "\(CryptoConstants.replayWindowSize) frames", .blue)
                    statusRow("Max Jitter", "\(CryptoConstants.maxAcceptableJitter)s", .blue)
                    statusRow("Alerts", "\(threatCount)", threatCount > 0 ? .orange : .green)
                }

                if !compliance.issues.isEmpty {
                    sectionCard(title: "Issues") {
                        ForEach(compliance.issues, id: \.self) { issue in
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                Text(issue)
                                    .font(.caption)
                            }
                        }
                    }
                }
            }
            .padding()
        }
        .onAppear {
            secureEnclaveAvailable = SecureEnclaveManager.isAvailable
        }
    }

    @ViewBuilder
    private func sectionCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .padding(.bottom, 4)
            content()
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }

    private func statusRow(_ label: String, _ value: String, _ color: Color) -> some View {
        HStack {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.subheadline)
            Spacer()
            Text(value)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
    }
}
