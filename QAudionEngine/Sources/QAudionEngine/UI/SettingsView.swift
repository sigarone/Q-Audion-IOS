import SwiftUI

/// Full settings view matching Android QAudionSettingsScreen.
public struct SettingsView: View {
    @EnvironmentObject var appState: QAudionAppState
    @State private var serverUrl = ""
    @State private var showLogoutConfirm = false

    public init() {}

    public var body: some View {
        NavigationView {
            List {
                // Profile section
                Section("Profilo") {
                    HStack {
                        Circle()
                            .fill(QColors.cardSurface)
                            .frame(width: 56, height: 56)
                            .overlay(
                                Image(systemName: "person.fill")
                                    .font(.title2)
                                    .foregroundColor(QColors.textTertiary)
                            )
                        VStack(alignment: .leading) {
                            Text(appState.backend?.identifier ?? "BCrypto")
                                .font(.headline)
                            Text("User ID: \(appState.backend?.getRestClient().serverUrl ?? "N/A")")
                                .font(.caption)
                                .foregroundColor(QColors.textTertiary)
                        }
                    }
                }

                // Security section
                Section("Sicurezza") {
                    NavigationLink(destination: SecurityDashboardView()) {
                        Label("Dashboard Sicurezza", systemImage: "shield.fill")
                    }
                    NavigationLink(destination: KeyManagementView()) {
                        Label("Gestione Chiavi", systemImage: "key.fill")
                    }
                    NavigationLink(destination: DeviceManagementView()) {
                        Label("Dispositivi", systemImage: "desktopcomputer")
                    }
                    NavigationLink(destination: VoiceEnrollmentView()) {
                        Label("Impronta Vocale", systemImage: "waveform")
                    }
                }

                // Identity section
                Section("Identita'") {
                    NavigationLink(destination: QrIdentityView()) {
                        Label("QR Identita' Sovrana", systemImage: "qrcode")
                    }
                    NavigationLink(destination: SasVerificationView()) {
                        Label("Verifica SAS", systemImage: "checkmark.shield")
                    }
                }

                // Network section
                Section("Rete") {
                    HStack {
                        Text("Server")
                        Spacer()
                        Text(appState.backend?.getRestClient().serverUrl ?? "N/A")
                            .foregroundColor(QColors.textSecondary)
                            .font(.caption)
                    }
                    HStack {
                        Text("Connessione")
                        Spacer()
                        HStack(spacing: 4) {
                            Circle()
                                .fill(appState.backend?.isConnected == true ? QColors.qGreen : QColors.error)
                                .frame(width: 8, height: 8)
                            Text(appState.backend?.isConnected == true ? "Connesso" : "Disconnesso")
                                .font(.caption)
                                .foregroundColor(QColors.textSecondary)
                        }
                    }
                }

                // About section
                Section("Informazioni") {
                    HStack {
                        Text("Versione")
                        Spacer()
                        Text("1.0.0")
                            .foregroundColor(QColors.textSecondary)
                    }
                    HStack {
                        Text("Protocollo")
                        Spacer()
                        Text("v1 (QUAD)")
                            .foregroundColor(QColors.textSecondary)
                    }
                    HStack {
                        Text("Crypto")
                        Spacer()
                        Text("ML-KEM-1024 + X25519")
                            .foregroundColor(QColors.qGreen)
                            .font(.caption)
                    }
                }

                // Logout
                Section {
                    Button(role: .destructive, action: { showLogoutConfirm = true }, label: {
                        Label("Disconnetti", systemImage: "rectangle.portrait.and.arrow.right")
                    })
                }
            }
            .navigationTitle("Impostazioni")
            .alert("Disconnetti?", isPresented: $showLogoutConfirm, actions: {
                Button("Annulla", role: .cancel) {}
                Button("Disconnetti", role: .destructive) {
                    Task { await appState.logout() }
                }
            }, message: {
                Text("Verrai disconnesso dal server BCrypto.")
            })
        }
    }
}
