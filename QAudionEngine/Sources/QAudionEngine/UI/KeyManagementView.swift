#if canImport(SwiftUI)
import SwiftUI

public struct KeyManagementView: View {
    @State private var keys: [(name: String, fingerprint: String)] = [
        ("Home Key", "a1b2c3d4..."),
        ("Office Key", "e5f6g7h8...")
    ]
    @State private var showingImport = false

    public init() {}

    public var body: some View {
        List {
            Section("Pre-Shared Keys") {
                ForEach(keys, id: \.name) { key in
                    VStack(alignment: .leading) {
                        Text(key.name).font(.headline)
                        Text(key.fingerprint)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .onDelete { indices in keys.remove(atOffsets: indices) }
            }

            Section {
                Button(action: { showingImport = true }) {
                    Label("Import Key via QR", systemImage: "qrcode.viewfinder")
                }
                NavigationLink(destination: NfcExchangeView()) {
                    Label("Import Key via NFC", systemImage: "wave.3.right")
                }
                Button(action: {}) {
                    Label("Generate New Key", systemImage: "key.fill")
                }
            }
        }
        .navigationTitle("Key Management")
        .sheet(isPresented: $showingImport) { QrScanView() }
    }
}
#endif
