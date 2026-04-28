import SwiftUI
import QAudionEngine

@MainActor
final class AboutSettingsContainer: ObservableObject {
    @Published var viewModel: AboutSettingsViewModel
    init(initial: AboutSettingsViewModel = .mock) { self.viewModel = initial }
}

struct AboutSettingsScreen: View {
    @ObservedObject var container: AboutSettingsContainer
    @StateObject private var updateChecker: AppUpdateChecker

    init(state: AppState) {
        let c = AboutSettingsContainer()
        self._container = ObservedObject(wrappedValue: c)
        _updateChecker = StateObject(wrappedValue: AppUpdateChecker(appState: state))
    }

    var body: some View {
        Form {
            Section("Version") {
                LabeledContent("App Version") {
                    Text(container.viewModel.appVersion)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Build Number") {
                    Text(container.viewModel.buildNumber)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Git Commit") {
                    Text(container.viewModel.gitCommitShort)
                        .font(.body.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            Section("Platform") {
                LabeledContent("iOS Deployment Target") {
                    Text("iOS \(container.viewModel.iosDeploymentTarget)+")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Security") {
                LabeledContent("ML-KEM-1024 (PQC)") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(container.viewModel.mlKem1024Enabled ? Color.green : Color.red)
                            .frame(width: 8, height: 8)
                        Text(container.viewModel.mlKem1024Enabled ? "Enabled" : "Disabled")
                            .foregroundStyle(container.viewModel.mlKem1024Enabled ? .green : .red)
                    }
                }
                LabeledContent("ONNX Runtime") {
                    Text(container.viewModel.onnxruntimeVersion)
                        .font(.body.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            Section("Updates") {
                if let result = updateChecker.lastResult {
                    switch result {
                    case .noUpdate:
                        Label("You're up to date", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case .updateAvailable(let info):
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Update available: v\(info.availableVersion)", systemImage: "arrow.down.circle.fill")
                                .foregroundStyle(.blue)
                            if !info.releaseNotes.isEmpty {
                                Text(info.releaseNotes)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if info.downloadUrl != nil {
                                Button("Open App Store") {
                                    updateChecker.openAppStoreLink(for: info)
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            }
                        }
                    case .error(let msg):
                        Label(msg, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.caption)
                    }
                }

                if let last = updateChecker.lastChecked {
                    LabeledContent("Last checked") {
                        Text(last, style: .relative)
                    }
                    .font(.caption)
                }

                Button(action: { Task { await updateChecker.checkForUpdates() } }) {
                    HStack {
                        Image(systemName: "arrow.clockwise.circle")
                        Text("Check for updates")
                        if updateChecker.isChecking {
                            Spacer()
                            ProgressView().scaleEffect(0.8)
                        }
                    }
                }
                .disabled(updateChecker.isChecking)
            }
        }
        .navigationTitle("About")
    }
}
