#if canImport(SwiftUI)
import SwiftUI

public struct QrScanView: View {
    @State private var scannedData: String?
    @State private var isShowingScanner = true
    @Environment(\.dismiss) private var dismiss

    public init() {}

    public var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                if isShowingScanner {
                    ZStack {
                        Rectangle()
                            .fill(Color.black)
                            .aspectRatio(1, contentMode: .fit)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.white, lineWidth: 3)
                                    .padding(40)
                            )
                        Text("Camera Preview\n(AVCaptureSession)")
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                    }
                    .cornerRadius(12)
                    .padding()

                    Text("Point camera at Q-Audion QR code")
                        .foregroundColor(.secondary)
                } else if let data = scannedData {
                    Label("Key scanned successfully", systemImage: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.title3)
                    Text(data).font(.caption).foregroundColor(.secondary)
                    Button("Done") { dismiss() }
                        .buttonStyle(.borderedProminent)
                }
            }
            .navigationTitle("Scan QR Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
#endif
