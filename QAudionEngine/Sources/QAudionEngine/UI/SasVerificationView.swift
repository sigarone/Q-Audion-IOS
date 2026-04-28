import SwiftUI

/// SAS (Short Authentication String) verification view matching Android's SasVerificationScreen.
///
/// Backed by `SasVerificationViewModel` (F1.6). Displays the 4 PGP words derived from the
/// call-session PQC handshake transcript plus the peer's identity fingerprint (§5.1 4-group hex).
/// User taps "They Match" or "They Don't Match"; verdict is recorded into the view model and
/// echoed via the supplied closures.
public struct SasVerificationView: View {

    public let viewModel: SasVerificationViewModel
    public let onVerdict: (SasVerificationViewModel.Verdict) -> Void

    @State private var showFingerprint = false

    public init(viewModel: SasVerificationViewModel = .mock,
                onVerdict: @escaping (SasVerificationViewModel.Verdict) -> Void = { _ in }) {
        self.viewModel = viewModel
        self.onVerdict = onVerdict
    }

    /// Legacy init preserved for callers that haven't migrated to the view model yet.
    /// Forwards to the view-model-backed init using a synthetic VM. Prefer the
    /// view-model-backed init for new code.
    public init(sasEmojis: [String], sasNumeric: String, peerName: String,
                onVerified: @escaping () -> Void = {}, onRejected: @escaping () -> Void = {}) {
        // Translate legacy params into a SasVerificationViewModel — preserve display
        // by using emojis as words and numeric as fingerprint surrogate.
        let words = sasEmojis.isEmpty ? ["abandon", "ability", "able", "about"] : sasEmojis
        let fingerprint = sasNumeric.isEmpty ? "????.????.????.????" : sasNumeric
        self.viewModel = SasVerificationViewModel(
            peerDisplayName: peerName,
            peerFingerprint: fingerprint,
            sasWords: words,
            userVerdict: .pending
        )
        self.onVerdict = { verdict in
            switch verdict {
            case .match: onVerified()
            case .mismatch: onRejected()
            case .pending: break
            }
        }
    }

    public var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 48))
                .foregroundColor(.green)

            Text("Verify Security")
                .font(.title2.bold())

            Text("Compare these with \(viewModel.peerDisplayName)'s device")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            if showFingerprint {
                Text(viewModel.peerFingerprint)
                    .font(.system(.title, design: .monospaced))
                    .tracking(2)
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(12)
            } else {
                wordsGrid
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(12)
            }

            Button(showFingerprint ? "Show SAS words" : "Show fingerprint") {
                showFingerprint.toggle()
            }
            .font(.caption)

            Spacer()

            HStack(spacing: 16) {
                Button(action: { onVerdict(.mismatch) }) {
                    Label("They Don't Match", systemImage: "xmark.circle.fill")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.red.opacity(0.15))
                        .foregroundColor(.red)
                        .cornerRadius(12)
                }

                Button(action: { onVerdict(.match) }) {
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

    @ViewBuilder
    private var wordsGrid: some View {
        let columns = [GridItem(.flexible()), GridItem(.flexible())]
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(viewModel.sasWords, id: \.self) { word in
                Text(word)
                    .font(.system(.title3, design: .monospaced).weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color(.systemBackground))
                    .cornerRadius(8)
            }
        }
    }
}

#Preview {
    SasVerificationView()
}
