#if canImport(SwiftUI)
import SwiftUI

public struct KeyManagementView: View {
    public let viewModel: KeyManagementViewModel
    /// Optional callback for the destructive "Rotate key" action. The
    /// sovereign key vault wipe + re-derive flow lives in the host app
    /// (it needs the live `BCryptoBackendProvider`), so this view stays
    /// transport-agnostic.
    public let onRotateKey: (() -> Void)?

    public init(
        viewModel: KeyManagementViewModel = .mock,
        onRotateKey: (() -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.onRotateKey = onRotateKey
    }

    @State private var showingIdentityQr = false
    @State private var showingRotateConfirm = false

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
                // W72: surface the existing QrIdentityView. Sheet keeps
                // navigation simple and lets the user dismiss with a
                // single swipe-down without losing context.
                Button {
                    showingIdentityQr = true
                } label: {
                    Label("Show Identity QR", systemImage: "qrcode")
                }
                // W72: rotate-key gate. The actual sovereign key wipe +
                // re-derive lives in the host app (needs the live
                // backend provider). The button only fires the
                // destructive confirmation here — the host wires the
                // closure to `SovereignIdentityManager.rotate()`.
                Button(role: .destructive) {
                    showingRotateConfirm = true
                } label: {
                    Label("Rotate key", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(onRotateKey == nil)
            }
        }
        .navigationTitle("Key Management")
        .sheet(isPresented: $showingIdentityQr) {
            NavigationStack {
                QrIdentityView()
                    .navigationTitle("Identity QR")
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
        .alert("Rotate identity key?", isPresented: $showingRotateConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Rotate", role: .destructive) { onRotateKey?() }
        } message: {
            Text("All paired contacts will need to re-verify your fingerprint after rotation. This action cannot be undone.")
        }
    }
}

#Preview {
    NavigationStack { KeyManagementView() }
}
#endif
