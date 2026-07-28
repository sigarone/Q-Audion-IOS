import SwiftUI
#if canImport(CoreImage)
import CoreImage.CIFilterBuiltins
#endif

/// QR code view for sovereign identity sharing, matching Android QrIdentityScreen.
public struct QrIdentityView: View {
    @State private var qrImage: Image?
    @State private var identityLink: String = ""
    @State private var showScanner = false

    private let manager = SovereignIdentityManager()

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Text("La tua Identita'")
                    .font(.title2.bold())
                    .foregroundColor(QColors.textPrimary)

                if let qr = qrImage {
                    qr
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 240, height: 240)
                        .padding()
                        .background(Color.white)
                        .cornerRadius(16)
                } else {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(QColors.cardSurface)
                        .frame(width: 240, height: 240)
                        .overlay(
                            VStack {
                                Image(systemName: "qrcode")
                                    .font(.system(size: 48))
                                    .foregroundColor(QColors.textTertiary)
                                Text("Nessuna identita'")
                                    .font(.caption)
                                    .foregroundColor(QColors.textTertiary)
                            }
                        )
                }

                if !identityLink.isEmpty {
                    VStack(spacing: 8) {
                        Text("Link condivisibile:")
                            .font(.caption)
                            .foregroundColor(QColors.textSecondary)

                        Text(identityLink)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundColor(QColors.qBlue)
                            .lineLimit(2)
                            .padding(8)
                            .background(QColors.cardSurface)
                            .cornerRadius(8)
                            .contextMenu {
                                Button("Copia") {
                                    #if canImport(UIKit)
                                    UIPasteboard.general.string = identityLink
                                    #endif
                                }
                            }

                        Button(action: shareLink) {
                            Label("Condividi", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(QColors.qGreen.opacity(0.15))
                                .foregroundColor(QColors.qGreen)
                                .cornerRadius(12)
                        }
                    }
                    .padding(.horizontal, 24)
                }

                Divider()

                Button(action: { showScanner = true }, label: {
                    Label("Scansiona identita' remota", systemImage: "qrcode.viewfinder")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(QColors.cardSurface)
                        .foregroundColor(QColors.qBlue)
                        .cornerRadius(12)
                })
                .padding(.horizontal, 24)
            }
            .padding()
        }
        .background(QColors.deepSpace)
        .navigationTitle("QR Identita'")
        .onAppear(perform: generateQR)
        .sheet(isPresented: $showScanner) {
            QrScanView()
        }
    }

    private func generateQR() {
        guard let identity = manager.loadIdentity() else { return }
        identityLink = manager.exportAsLink(identity)
        let qrData = manager.exportAsQrData(identity)

        #if canImport(CoreImage)
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.setValue(qrData, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")

        if let output = filter.outputImage {
            let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
            if let cgImage = context.createCGImage(scaled, from: scaled.extent) {
                #if canImport(UIKit)
                qrImage = Image(uiImage: UIImage(cgImage: cgImage))
                #else
                qrImage = Image(nsImage: NSImage(cgImage: cgImage, size: NSSize(width: 240, height: 240)))
                #endif
            }
        }
        #endif
    }

    private func shareLink() {
        #if canImport(UIKit)
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let root = scene.windows.first?.rootViewController else { return }
        let activity = UIActivityViewController(activityItems: [identityLink], applicationActivities: nil)
        root.present(activity, animated: true)
        #endif
    }
}
