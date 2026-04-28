import SwiftUI
import CoreImage.CIFilterBuiltins
import QAudionEngine

/// Shows the user's identity QR + fingerprint in a sheet, ready to be
/// scanned by a peer running `QrScannerSheet` on another device.
///
/// Symmetric to `QrScannerSheet` (scan-side surface): together they form
/// the in-person contact-pairing flow exposed from the ContactsListView
/// `+ menu`. Reuses `KeyRotationCoordinator` so the sheet always reflects
/// the current local identity (rotated keys propagate via @StateObject).
///
/// The QR is rendered with CoreImage's `qrCodeGenerator` filter at 8×
/// scale and `correctionLevel = M`, matching `KeyManagementScreen`.
/// The textual form is exposed via "Show as text" + "Copy to clipboard"
/// for fallback scenarios (peer's camera unavailable, paste over chat,
/// shared screenshot).
struct MyIdentityQrSheet: View {
    let appState: AppState

    @Environment(\.dismiss) private var dismiss
    @StateObject private var coordinator: KeyRotationCoordinator
    @State private var showingText: Bool = false

    init(appState: AppState) {
        self.appState = appState
        _coordinator = StateObject(wrappedValue: KeyRotationCoordinator(appState: appState))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Identity Fingerprint") {
                    Text(coordinator.currentFingerprint)
                        .font(.title3.monospaced().weight(.bold))
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 8)
                        .textSelection(.enabled)
                }

                if let qrString = coordinator.currentIdentityQr {
                    Section("Show My Identity") {
                        qrCodeImage(for: qrString)
                            .frame(height: 240)
                            .frame(maxWidth: .infinity)
                        Button("Show as text") { showingText = true }
                        Button("Copy to clipboard") {
                            UIPasteboard.general.string = qrString
                        }
                    }
                    Section {
                        Text("Have your contact tap **+ → Scan QR** in their Contacts tab and aim their camera at this code. Once they confirm, you'll appear in each other's verified contact list.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        Label("Identity QR not yet available — sign in first.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("My Identity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showingText) {
                NavigationStack {
                    if let qr = coordinator.currentIdentityQr {
                        ScrollView {
                            Text(qr)
                                .font(.body.monospaced())
                                .padding()
                                .textSelection(.enabled)
                        }
                        .navigationTitle("Identity Text")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Done") { showingText = false }
                            }
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
