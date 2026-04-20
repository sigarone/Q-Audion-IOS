import SwiftUI
import Contacts

/// Contact discovery view matching Android's ContactDiscoveryScreen.
/// Hashes phone numbers and discovers registered contacts on BCrypto server.
public struct ContactDiscoveryView: View {
    @EnvironmentObject var appState: QAudionAppState
    @Environment(\.dismiss) private var dismiss
    @State private var discovered: [DiscoveredContact] = []
    @State private var isScanning = false
    @State private var showQrScanner = false
    @State private var manualId = ""

    public init() {}

    public var body: some View {
        NavigationView {
            List {
                Section("Scansione QR") {
                    Button(action: { showQrScanner = true }) {
                        Label("Scansiona QR Code", systemImage: "qrcode.viewfinder")
                    }
                }

                Section("Aggiungi manualmente") {
                    HStack {
                        TextField("ID utente o link qaudion://", text: $manualId)
                        Button("Aggiungi") {
                            addManualContact()
                        }
                        .disabled(manualId.isEmpty)
                    }
                }

                Section("Scopri contatti dalla rubrica") {
                    Button(action: { Task { await discoverFromAddressBook() } }) {
                        if isScanning {
                            ProgressView()
                        } else {
                            Label("Cerca contatti registrati", systemImage: "person.crop.rectangle.stack")
                        }
                    }
                    .disabled(isScanning)
                }

                if !discovered.isEmpty {
                    Section("Trovati (\(discovered.count))") {
                        ForEach(discovered, id: \.userId) { contact in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(contact.displayName ?? contact.userId)
                                        .fontWeight(.medium)
                                    if let status = contact.statusMessage {
                                        Text(status)
                                            .font(.caption)
                                            .foregroundColor(QColors.textSecondary)
                                    }
                                }
                                Spacer()
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(QColors.qGreen)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Aggiungi Contatto")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Chiudi") { dismiss() }
                }
            }
            .sheet(isPresented: $showQrScanner) {
                QrScanView()
            }
        }
    }

    private func discoverFromAddressBook() async {
        isScanning = true
        defer { Task { @MainActor in isScanning = false } }

        let store = CNContactStore()
        var isAuthorized = CNContactStore.authorizationStatus(for: .contacts) == .authorized
        if !isAuthorized {
            isAuthorized = (try? await store.requestAccess(for: .contacts)) ?? false
        }
        guard isAuthorized else { return }

        let request = CNContactFetchRequest(keysToFetch: [CNContactPhoneNumbersKey as CNKeyDescriptor])
        var phoneHashes: [String] = []

        try? store.enumerateContacts(with: request) { contact, _ in
            for phone in contact.phoneNumbers {
                let raw = phone.value.stringValue
                if let hash = PhoneHash.hashOrNil(raw) {
                    phoneHashes.append(hash)
                }
            }
        }

        guard !phoneHashes.isEmpty, let api = appState.backend?.contactsApi else { return }

        do {
            let results = try await api.discoverContacts(phoneHashes: phoneHashes)
            await MainActor.run { discovered = results }
        } catch { /* silently fail */ }
    }

    private func addManualContact() {
        // Check if it's a sovereign identity link
        let mgr = SovereignIdentityManager()
        if let identity = mgr.parseIdentityLink(manualId) {
            // Add as contact
            Task {
                try? await appState.backend?.contactsApi.addContact(userId: identity.userId)
                await appState.loadContacts()
                await MainActor.run { dismiss() }
            }
        } else if !manualId.isEmpty {
            Task {
                try? await appState.backend?.contactsApi.addContact(userId: manualId)
                await appState.loadContacts()
                await MainActor.run { dismiss() }
            }
        }
    }
}
