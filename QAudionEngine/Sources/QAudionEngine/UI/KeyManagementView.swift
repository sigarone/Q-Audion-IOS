#if canImport(SwiftUI)
import SwiftUI

public struct KeyManagementView: View {
    public let viewModel: KeyManagementViewModel

    public init(viewModel: KeyManagementViewModel = .mock) {
        self.viewModel = viewModel
    }

    public var body: some View {
        Form {
            Section("Identity") {
                LabeledContent("User ID") {
                    Text(viewModel.userId).font(.caption.monospaced()).lineLimit(1)
                }
                LabeledContent("Fingerprint") {
                    Text(viewModel.fingerprint).font(.body.monospaced())
                }
                if let lastRot = viewModel.lastKeyRotation {
                    LabeledContent("Last rotation") {
                        Text(lastRot, style: .relative).foregroundStyle(.secondary)
                    }
                }
            }
            Section("Linked devices") {
                ForEach(viewModel.linkedDevices, id: \.deviceId) { d in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(d.deviceName)
                            Text(d.deviceId).font(.caption2.monospaced()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if d.isCurrentDevice {
                            Text("This device").font(.caption).foregroundStyle(.green)
                        }
                    }
                }
            }
            Section("Actions") {
                NavigationLink(destination: NfcExchangeView()) {
                    Label("Import Key via NFC", systemImage: "wave.3.right")
                }
                Button("Show Identity QR") { /* TODO: A.2 D.x QR push */ }
                Button("Rotate key", role: .destructive) { /* TODO: rotation flow */ }
            }
        }
        .navigationTitle("Key Management")
    }
}

#Preview {
    NavigationStack { KeyManagementView() }
}
#endif
