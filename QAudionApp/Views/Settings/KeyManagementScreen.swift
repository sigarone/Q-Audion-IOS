import SwiftUI
import QAudionEngine

/// Key management: where the pre-shared keys of calls come from, and the order in which they are tried.
///
/// Top to bottom, the same as on Android: the KMS row (status of the key delivery and "Aggiorna"), "Associa di
/// persona" (QR + Bluetooth, with another person), NFC (with an Android phone), then the keys that take part in
/// calls. The list is the call-key priority of docs/security/CALL_KEY_PRIORITY.md: by default the KMS key is the
/// call key and an in-person key confirms it; the arrows put one above another, and a key placed by hand keeps its
/// place when a new KMS key arrives.
struct KeyManagementScreen: View {
    @StateObject private var coordinator: KeyManagementCoordinator
    /// The address-book side of an in-person pairing started from here: the same bookkeeping Contacts runs
    /// (contact added if missing, outcome, telemetry).
    @StateObject private var contacts: ContactsListContainer
    @ObservedObject private var kmsStatus = KmsSweepStatus.shared
    @State private var pendingDeleteKeyId: String?
    @State private var showingProximityPair = false
    @State private var proximityOutcome: ContactsListContainer.ProximityOutcome?

    private let appState: AppState
    /// Whether this device can read NFC tags; the NFC row is replaced by a
    /// neutral line when it cannot.
    private let nfcAvailability: NfcAvailability = .device

    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType) private var type

    init(state: AppState) {
        self.appState = state
        _coordinator = StateObject(wrappedValue: KeyManagementCoordinator())
        _contacts = StateObject(wrappedValue: ContactsListContainer(appState: state))
    }

    var body: some View {
        ZStack {
            scheme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    kmsRow
                    pairInPersonRow
                    nfcRow
                    SettingsSectionHeader(keysHeader)
                    keyList
                    Spacer().frame(height: 24)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }
            // At the bottom of the screen, not in the list: an arrow press can be far from the top of a long list.
            .safeAreaInset(edge: .bottom) {
                if let message = coordinator.errorMessage {
                    errorBanner(message)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                        .background(scheme.background)
                }
            }
        }
        .navigationTitle("Gestione chiavi")
        .alert("Eliminare questa chiave?",
               isPresented: Binding(
                   get: { pendingDeleteKeyId != nil },
                   set: { if !$0 { pendingDeleteKeyId = nil } }
               )) {
            Button("Annulla", role: .cancel) { pendingDeleteKeyId = nil }
            Button("Elimina", role: .destructive) {
                if let id = pendingDeleteKeyId {
                    coordinator.deleteKey(id)
                }
                pendingDeleteKeyId = nil
            }
        } message: {
            if deletionNeedsWarning {
                Text("key_management.delete_pending_warning")
            } else {
                Text("La chiave verrà rimossa dal vault locale. Se serve di nuovo, andrà ri-scambiata con il contatto.")
            }
        }
        .sheet(isPresented: $showingProximityPair) {
            ProximityPairingChooserSheet(
                localUserId: appState.currentUserId,
                serverIdentityKeys: { (userId: String) async -> Set<Data> in
                    await contacts.publishedIdentityKeys(userId)
                },
                onCompleted: { result in handleProximityPaired(result) })
        }
        .sheet(item: $proximityOutcome) { outcome in
            ProximityOutcomeResultSheet(outcome: outcome) { proximityOutcome = nil }
        }
    }

    /// The key about to be deleted is part of a pairing still waiting for confirmation (section 4a).
    private var deletionNeedsWarning: Bool {
        guard let id = pendingDeleteKeyId, let row = coordinator.keys.first(where: { $0.id == id }) else { return false }
        return row.pending != .none
    }

    // MARK: - KMS

    private var kmsRow: some View {
        HStack(spacing: 14) {
            Image(systemName: "server.rack")
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(extras.pqcAccent)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text("KMS")
                    .qaudionStyle(type.bodyMedium)
                    .foregroundStyle(scheme.onSurface)
                Text(verbatim: kmsStatusText)
                    .qaudionStyle(type.labelSmall)
                    .foregroundStyle(scheme.onSurfaceVariant)
                    .lineLimit(2)
            }
            Spacer(minLength: 6)
            Button {
                Task { await appState.pollKmsNow() }
            } label: {
                if kmsStatus.isRunning {
                    ProgressView().progressViewStyle(.circular)
                } else {
                    Text("Aggiorna")
                        .qaudionStyle(type.labelLarge)
                        .foregroundStyle(scheme.primary)
                }
            }
            .buttonStyle(.plain)
            .disabled(kmsStatus.isRunning)
            .frame(minWidth: 64, minHeight: 44)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 56)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(scheme.surfaceVariant.opacity(0.4))
        )
    }

    private var kmsStatusText: String {
        switch kmsStatus.state {
        case .idle:
            return String(
                localized: "key_management.kms_idle",
                defaultValue: "Il server consegna le chiavi qui appena disponibili.",
                comment: "Key management, KMS row — status line before any key delivery check has finished")
        case .running:
            return String(
                localized: "key_management.kms_running",
                defaultValue: "Aggiornamento in corso…",
                comment: "Key management, KMS row — status line while the app asks the server for new keys")
        case .succeeded(let date):
            let time: String = Self.timeText(date)
            return String(
                localized: "key_management.kms_last_update",
                defaultValue: "Ultimo aggiornamento: \(time)",
                comment: "Key management, KMS row — status line after a successful check; %@ is the time of day")
        case .failed:
            return String(
                localized: "key_management.kms_failed",
                defaultValue: "Aggiornamento non riuscito.",
                comment: "Key management, KMS row — status line after the check for new keys failed")
        }
    }

    private static func timeText(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute().locale(Locale(identifier: AppLanguageManager.effectiveLanguageCode)))
    }

    // MARK: - In person and NFC

    private var pairInPersonRow: some View {
        Button {
            showingProximityPair = true
        } label: {
            SettingsRow(icon: "person.2.wave.2",
                        iconColor: extras.pqcAccent,
                        title: "Associa di persona")
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var nfcRow: some View {
        if nfcAvailability.isAvailable {
            NavigationLink {
                NfcExchangeView(localUserId: appState.currentUserId ?? "",
                                serverIdentityKeys: { (userId: String) async -> Set<Data> in
                                    await contacts.publishedIdentityKeys(userId)
                                })
            } label: {
                SettingsRow(icon: "wave.3.right",
                            iconColor: extras.pqcAccent,
                            title: "Accoppia via NFC",
                            subtitle: "Funziona con un telefono Android")
            }
            .buttonStyle(.plain)
        } else {
            Text(NfcAvailability.unavailableMessage)
                .qaudionStyle(type.labelSmall)
                .foregroundStyle(scheme.onSurfaceVariant)
                .padding(.horizontal, 14)
        }
    }

    /// The pairing sheet closed itself when the pairing finished; what is left is the address-book side and the
    /// final screen of the outcome.
    private func handleProximityPaired(_ result: ProximityPairingSummary) {
        let outcome: ContactsListContainer.ProximityOutcome = contacts.recordProximityPairing(result)
        showingProximityPair = false
        proximityOutcome = outcome
        coordinator.loadKeys()
    }

    // MARK: - The keys

    private var keysHeader: String {
        let count: Int = coordinator.keys.count
        return String(
            localized: "key_management.section_keys",
            defaultValue: "CHIAVI DISPONIBILI (\(count))",
            comment: "Key management — header above the list of call keys; %lld is how many there are")
    }

    @ViewBuilder
    private var keyList: some View {
        if coordinator.keys.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Nessuna chiave presente")
                    .qaudionStyle(type.bodyMedium)
                    .foregroundStyle(scheme.onSurface)
                Text("Usa Associa di persona o NFC con un'altra persona, oppure aggiorna il KMS per ricevere le chiavi del server.")
                    .qaudionStyle(type.labelSmall)
                    .foregroundStyle(scheme.onSurfaceVariant)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(scheme.surfaceVariant.opacity(0.4)))
        } else {
            VStack(spacing: 8) {
                ForEach(coordinator.keys) { row in
                    keyRow(row)
                }
            }
        }
    }

    private func keyRow(_ row: KeyManagementRow) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "key.fill")
                .font(.system(size: 14))
                .foregroundStyle(extras.pqcAccent)
                .frame(width: 22)
            keyDescription(row)
            Spacer(minLength: 6)
            priorityArrows(row)
            deleteButton(row)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(minHeight: 72)
        .background(RoundedRectangle(cornerRadius: 12).fill(scheme.surfaceVariant.opacity(0.4)))
    }

    private func keyDescription(_ row: KeyManagementRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            originLabel(row)
                .qaudionStyle(type.bodyMedium)
                .foregroundStyle(scheme.onSurface)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(verbatim: row.fingerprint)
                .qaudionStyle(type.labelSmall)
                .foregroundStyle(scheme.onSurfaceVariant)
                .font(.system(.caption, design: .monospaced))
            Text("Priorità \(row.priority)")
                .qaudionStyle(type.labelSmall)
                .foregroundStyle(scheme.onSurfaceVariant)
            if row.pending == .waiting {
                Text("key_management.waiting_confirmation")
                    .qaudionStyle(type.labelSmall)
                    .foregroundStyle(scheme.onSurfaceVariant)
            }
        }
    }

    /// Up and down: one place each, always enabled (a move at the edge changes nothing but still marks the key as
    /// placed by hand, as on Android).
    private func priorityArrows(_ row: KeyManagementRow) -> some View {
        VStack(spacing: 0) {
            arrowButton(systemImage: "chevron.up", label: "Aumenta priorità") {
                coordinator.moveUp(row.id)
            }
            arrowButton(systemImage: "chevron.down", label: "Riduci priorità") {
                coordinator.moveDown(row.id)
            }
        }
    }

    private func arrowButton(systemImage: String, label: LocalizedStringKey,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(scheme.primary)
                .frame(width: 44, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func deleteButton(_ row: KeyManagementRow) -> some View {
        Button {
            pendingDeleteKeyId = row.id
        } label: {
            Image(systemName: "trash")
                .font(.system(size: 14))
                .foregroundStyle(extras.riskHigh.opacity(0.7))
                .frame(width: 36, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Elimina chiave")
    }

    private func errorBanner(_ msg: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(extras.riskHigh)
                .padding(.top, 1)
            Text(msg)
                .qaudionStyle(type.labelSmall)
                .foregroundStyle(extras.riskHigh)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(extras.riskHigh.opacity(0.12))
        )
    }

    /// What the key is called: where it came from, or the name it was given when it came from nowhere known.
    private func originLabel(_ row: KeyManagementRow) -> Text {
        switch row.origin {
        case .kms:
            return Text("KMS")
        case .nfc:
            return Text("NFC")
        case .proximity:
            return Text("Associa di persona")
        default:
            return Text(verbatim: row.id)
        }
    }
}
