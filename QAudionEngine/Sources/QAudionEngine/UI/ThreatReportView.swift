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

            Section("Detected event") {
                LabeledContent("Type") {
                    Text(viewModel.threatKind.displayLabel)
                }
                LabeledContent("Severity") {
                    Text(viewModel.severity.displayLabel)
                        .foregroundStyle(viewModel.severity.color)
                }
                LabeledContent("Detected") {
                    Text(viewModel.detectedAt, style: .relative)
                        .foregroundStyle(.secondary)
                }
                if let sid = viewModel.sessionId {
                    LabeledContent("Session") {
                        Text(sid).font(.caption.monospaced()).lineLimit(1)
                    }
                }
            }

            Section("Auto-collected detail") {
                Text(viewModel.detail)
                    .font(.body)
            }

            Section("Add your notes (optional)") {
                TextField("Describe what happened…", text: $draftDetail, axis: .vertical)
                    .lineLimit(3...6)
            }

            Section {
                Button("Submit threat report") {
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
                    Button("Cancel", action: dismiss)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Text("Threat reports help us improve detection. The report includes the threat type, severity, and your notes — never your call audio or messages.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Threat Report")
    }

    private var severityHeader: some View {
        HStack {
            Image(systemName: viewModel.severity.symbol)
                .font(.title)
                .foregroundStyle(viewModel.severity.color)
            VStack(alignment: .leading) {
                Text("Threat detected").font(.headline)
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
        case .deepfakeDetected: return "Deepfake detected"
        case .voiceMismatch: return "Voice mismatch"
        case .keyTampering: return "Key tampering"
        case .suspiciousNetwork: return "Suspicious network"
        case .panicWipeTriggered: return "Panic wipe triggered"
        case .other: return "Other"
        }
    }
}

extension ThreatReportViewModel.Severity {
    var displayLabel: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .critical: return "Critical"
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
