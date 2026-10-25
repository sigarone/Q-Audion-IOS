import SwiftUI

public struct ThreatReportView: View {

    public let viewModel: ThreatReportViewModel
    public var onSubmit: (ThreatReportViewModel) -> Void
    public var onDismiss: (() -> Void)?

    @State private var draftDetail: String

    public init(viewModel: ThreatReportViewModel = .mock,
                onSubmit: @escaping (ThreatReportViewModel) -> Void = { _ in },
                onDismiss: (() -> Void)? = nil) {
        self.viewModel = viewModel
        self.onSubmit = onSubmit
        self.onDismiss = onDismiss
        self._draftDetail = State(initialValue: viewModel.userTypedDetail)
    }

    public var body: some View {
        Form {
            Section {
                severityHeader
            }

            Section("Evento rilevato") {
                LabeledContent("Tipo") {
                    Text(viewModel.threatKind.displayLabel)
                }
                LabeledContent("Gravità") {
                    Text(viewModel.severity.displayLabel)
                        .foregroundStyle(viewModel.severity.color)
                }
                LabeledContent("Rilevato") {
                    Text(viewModel.detectedAt, style: .relative)
                        .foregroundStyle(.secondary)
                }
                if let sid = viewModel.sessionId {
                    LabeledContent("Sessione") {
                        Text(sid).font(.caption.monospaced()).lineLimit(1)
                    }
                }
            }

            Section("Dettaglio raccolto automaticamente") {
                Text(viewModel.detail)
                    .font(.body)
            }

            Section("Aggiungi le tue note (facoltative)") {
                TextField("Descrivi cosa è successo…", text: $draftDetail, axis: .vertical)
                    .lineLimit(3...6)
            }

            Section {
                Button("Invia la segnalazione") {
                    let submitted = ThreatReportViewModel(
                        threatKind: viewModel.threatKind,
                        severity: viewModel.severity,
                        detail: viewModel.detail,
                        detectedAt: viewModel.detectedAt,
                        sessionId: viewModel.sessionId,
                        userTypedDetail: draftDetail
                    )
                    onSubmit(submitted)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .foregroundStyle(.red)

                if let dismiss = onDismiss {
                    Button("Annulla", action: dismiss)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Text("Le segnalazioni ci aiutano a migliorare il rilevamento. Includono il tipo di minaccia, la gravità e le tue note: mai l'audio delle chiamate o i tuoi messaggi.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Segnalazione di minaccia")
    }

    private var severityHeader: some View {
        HStack {
            Image(systemName: viewModel.severity.symbol)
                .font(.title)
                .foregroundStyle(viewModel.severity.color)
            VStack(alignment: .leading) {
                Text("Minaccia rilevata").font(.headline)
                Text(viewModel.severity.displayLabel)
                    .font(.subheadline)
                    .foregroundStyle(viewModel.severity.color)
            }
        }
    }
}

extension ThreatReportViewModel.ThreatKind {
    var displayLabel: String {
        switch self {
        case .deepfakeDetected:
            return String(localized: "security.threat_category.deepfake", defaultValue: "Deepfake rilevato", comment: "Threat report category: a deepfake (synthetic voice or video) was detected")
        case .voiceMismatch:
            return String(localized: "security.threat_category.voice_mismatch", defaultValue: "Voce non corrispondente", comment: "Threat report category: the voice did not match the saved voice of the contact")
        case .keyTampering:
            return String(localized: "security.threat_category.key_tampering", defaultValue: "Manomissione chiavi", comment: "Threat report category: signs that encryption keys were tampered with")
        case .suspiciousNetwork:
            return String(localized: "security.threat_category.suspicious_network", defaultValue: "Rete sospetta", comment: "Threat report category: suspicious network behavior")
        case .panicWipeTriggered:
            return String(localized: "security.threat_category.panic_wipe", defaultValue: "Wipe di emergenza attivato", comment: "Threat report category: the emergency wipe (erasing all data) was triggered")
        case .other:
            return String(localized: "Altro")
        }
    }
}

extension ThreatReportViewModel.Severity {
    var displayLabel: String {
        switch self {
        case .low: return String(localized: "security.severity.low", defaultValue: "Bassa", comment: "Threat report severity (feminine, agrees with 'gravity'): low")
        case .medium: return String(localized: "security.severity.medium", defaultValue: "Media", comment: "Threat report severity (feminine, agrees with 'gravity'): medium")
        case .high: return String(localized: "security.severity.high", defaultValue: "Alta", comment: "Threat report severity (feminine, agrees with 'gravity'): high")
        case .critical: return String(localized: "security.severity.critical", defaultValue: "Critica", comment: "Threat report severity (feminine, agrees with 'gravity'): critical")
        }
    }

    var color: Color {
        switch self {
        case .low: return .blue
        case .medium: return .orange
        case .high: return .red
        case .critical: return .purple
        }
    }

    var symbol: String {
        switch self {
        case .low: return "info.circle.fill"
        case .medium: return "exclamationmark.triangle.fill"
        case .high: return "exclamationmark.shield.fill"
        case .critical: return "shield.lefthalf.filled.slash"
        }
    }
}

#Preview {
    NavigationStack { ThreatReportView() }
}
