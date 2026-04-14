import SwiftUI

/// SAS (Short Authentication String) verification view matching Android's SasVerificationScreen.
/// Displays emoji or numeric SAS for manual verification of the encrypted channel.
public struct SasVerificationView: View {
    public let sasEmojis: [String]
    public let sasNumeric: String
    public let peerName: String
    public let onVerified: () -> Void
    public let onRejected: () -> Void

    @State private var showNumeric = false

    public init(sasEmojis: [String] = [], sasNumeric: String = "", peerName: String = "",
                onVerified: @escaping () -> Void = {}, onRejected: @escaping () -> Void = {}) {
        self.sasEmojis = sasEmojis
        self.sasNumeric = sasNumeric
        self.peerName = peerName
        self.onVerified = onVerified
        self.onRejected = onRejected
    }

    public var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 48))
                .foregroundColor(.green)

            Text("Verify Security")
                .font(.title2.bold())

            Text("Compare these with \(peerName)'s device")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            if showNumeric {
                Text(sasNumeric)
                    .font(.system(.title, design: .monospaced))
                    .tracking(4)
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(12)
            } else {
                HStack(spacing: 16) {
                    ForEach(sasEmojis, id: \.self) { emoji in
                        Text(emoji)
                            .font(.system(size: 40))
                    }
                }
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(12)
            }

            Button(showNumeric ? "Show Emojis" : "Show Numbers") {
                showNumeric.toggle()
            }
            .font(.caption)

            Spacer()

            HStack(spacing: 16) {
                Button(action: onRejected) {
                    Label("They Don't Match", systemImage: "xmark.circle.fill")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.red.opacity(0.15))
                        .foregroundColor(.red)
                        .cornerRadius(12)
                }

                Button(action: onVerified) {
                    Label("They Match", systemImage: "checkmark.circle.fill")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.green.opacity(0.15))
                        .foregroundColor(.green)
                        .cornerRadius(12)
                }
            }
        }
        .padding()
    }
}
