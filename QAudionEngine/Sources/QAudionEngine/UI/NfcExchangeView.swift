#if canImport(SwiftUI)
import SwiftUI

public struct NfcExchangeView: View {
    @State private var status = "Ready to scan"
    @State private var isScanning = false
    @State private var receivedKeyName: String?

    public init() {}

    public var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: isScanning ? "wave.3.right.circle.fill" : "wave.3.right.circle")
                .font(.system(size: 80))
                .foregroundColor(isScanning ? .blue : .gray)

            Text(status)
                .font(.headline)

            if let name = receivedKeyName {
                Label("Key received: \(name)", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
            }

            Button(isScanning ? "Stop Scanning" : "Start NFC Scan") {
                isScanning.toggle()
                status = isScanning ? "Hold device near NFC tag..." : "Ready to scan"
            }
            .buttonStyle(.borderedProminent)

            Spacer()

            Text("iOS can read NFC tags written by Q-Audion Android.\nFor iOS-to-iOS exchange, use QR code instead.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .navigationTitle("NFC Key Exchange")
        .padding()
    }
}
#endif
