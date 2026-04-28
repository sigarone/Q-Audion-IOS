import SwiftUI
import QAudionEngine

@MainActor
final class AboutSettingsContainer: ObservableObject {
    @Published var viewModel: AboutSettingsViewModel
    init(initial: AboutSettingsViewModel = .mock) { self.viewModel = initial }
}

struct AboutSettingsScreen: View {
    @ObservedObject var container: AboutSettingsContainer

    init(state: AppState) {
        let c = AboutSettingsContainer()
        self._container = ObservedObject(wrappedValue: c)
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
        }
        .navigationTitle("About")
    }
}
