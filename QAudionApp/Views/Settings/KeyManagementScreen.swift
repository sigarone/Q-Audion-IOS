import SwiftUI
import CoreImage.CIFilterBuiltins
import QAudionEngine

struct KeyManagementScreen: View {
    @StateObject private var coordinator: KeyRotationCoordinator
    @State private var showingRotateConfirm = false
    @State private var showingIdentityText = false

    private let appState: AppState

    init(state: AppState) {
        self.appState = state
        _coordinator = StateObject(wrappedValue: KeyRotationCoordinator(appState: state))
    }

    var body: some View {
        Form {
            Section("Identity Fingerprint") {
                Text(coordinator.currentFingerprint)
                    .font(.title3.monospaced().weight(.bold))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            }

            if let qrString = coordinator.currentIdentityQr {
                Section("Show My Identity") {
                    qrCodeImage(for: qrString)
                        .frame(height: 220)
                        .frame(maxWidth: .infinity)
                    Button("Show as text") {
                        showingIdentityText = true
                    }
                    Button("Copy to clipboard") {
                        UIPasteboard.general.string = qrString
                    }
                }
            }

            Section("Key Rotation") {
                if let last = coordinator.lastRotationDate {
                    LabeledContent("Last rotation") { Text(last, style: .relative) }
                }
                Button(action: { showingRotateConfirm = true }) {
                    HStack {
                        Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                            .foregroundStyle(.orange)
                        Text("Rotate Keys")
                            .foregroundStyle(.orange)
                        if coordinator.isRotating {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(coordinator.isRotating)
                Text("Rotating keys generates a new identity. Your contacts will see a different fingerprint and need to re-verify.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Devices") {
                NavigationLink("Linked devices") { DeviceManagementScreen(state: appState) }
                NavigationLink("Pair via NFC") {
                    NfcExchangeView()
                }
            }

            if let err = coordinator.errorMessage {
                Section {
                    Text(err).foregroundStyle(.red).font(.footnote)
                }
            }
        }
        .navigationTitle("Gestione chiavi")
        .alert("Rotate Keys?", isPresented: $showingRotateConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Rotate", role: .destructive) {
                coordinator.rotate()
            }
        } message: {
            Text("This generates new keys. All your contacts will need to re-verify your identity. Continue?")
        }
        .sheet(isPresented: $showingIdentityText) {
            NavigationStack {
                if let qr = coordinator.currentIdentityQr {
                    ScrollView {
                        Text(qr)
                            .font(.body.monospaced())
                            .padding()
                            .textSelection(.enabled)
                    }
                    .navigationTitle("Identity Text")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showingIdentityText = false }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func qrCodeImage(for content: String) -> some View {
        if let image = generateQrImage(from: content) {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
        } else {
            Text("QR generation failed").foregroundStyle(.red)
        }
    }

    private func generateQrImage(from content: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(content.utf8)
        filter.correctionLevel = "M"
        guard let outputImage = filter.outputImage else { return nil }
        let scale = CGAffineTransform(scaleX: 8, y: 8)
        let scaled = outputImage.transformed(by: scale)
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
