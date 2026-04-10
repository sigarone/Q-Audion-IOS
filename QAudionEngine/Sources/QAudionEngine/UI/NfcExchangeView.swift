#if canImport(SwiftUI)
import SwiftUI

public struct NfcExchangeView: View {
    @State private var status = "Ready to scan"
    @State private var isScanning = false
    @State private var receivedKeyName: String?
    @State private var errorMessage: String?

    private let nfcProtocol = NfcProtocol()

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

            if let error = errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
                    .font(.subheadline)
            }

            #if canImport(CoreNFC)
            Button(isScanning ? "Stop Scanning" : "Start NFC Scan") {
                if isScanning {
                    stopScanning()
                } else {
                    startScanning()
                }
            }
            .buttonStyle(.borderedProminent)
            #else
            Text("NFC not available")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.gray.opacity(0.15))
                .cornerRadius(8)
            #endif

            Spacer()

            Text("iOS can read NFC tags written by Q-Audion Android.\nFor iOS-to-iOS exchange, use QR code instead.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .navigationTitle("NFC Key Exchange")
        .padding()
        .onAppear {
            configureCallbacks()
        }
    }

    // MARK: - Private helpers

    private func configureCallbacks() {
        nfcProtocol.onPskReceived = { name, _ in
            receivedKeyName = name
            status = "Key exchange complete"
            isScanning = false
            errorMessage = nil
        }

        nfcProtocol.onStateChanged = { newState in
            switch newState {
            case .idle:
                isScanning = false
                if receivedKeyName == nil {
                    status = "Ready to scan"
                }
            case .reading:
                isScanning = true
                status = "Hold device near NFC tag..."
                errorMessage = nil
            case .complete:
                isScanning = false
                status = "Key exchange complete"
                errorMessage = nil
            case .error(let message):
                isScanning = false
                status = "Ready to scan"
                errorMessage = message
            }
        }
    }

    #if canImport(CoreNFC)
    private func startScanning() {
        errorMessage = nil
        nfcProtocol.startReading()
    }

    private func stopScanning() {
        nfcProtocol.stopReading()
    }
    #endif
}
#endif
