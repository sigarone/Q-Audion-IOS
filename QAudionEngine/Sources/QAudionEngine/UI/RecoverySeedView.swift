import SwiftUI

public struct RecoverySeedView: View {
    public let viewModel: RecoverySeedViewModel
    public var onConfirmSetup: ((String) -> Void)?  // recovery hash to send to server
    public var onVerifyMnemonic: (([String]) -> Void)?  // user-entered words to verify
    public var onDismiss: (() -> Void)?

    @State private var localTyped: [String] = Array(repeating: "", count: 12)

    public init(viewModel: RecoverySeedViewModel = .mock,
                onConfirmSetup: ((String) -> Void)? = nil,
                onVerifyMnemonic: (([String]) -> Void)? = nil,
                onDismiss: (() -> Void)? = nil) {
        self.viewModel = viewModel
        self.onConfirmSetup = onConfirmSetup
        self.onVerifyMnemonic = onVerifyMnemonic
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(spacing: 24) {
            switch viewModel.step {
            case .setupShowMnemonic:
                showMnemonicStep
            case .setupConfirmEntry, .verifyEnterMnemonic:
                enterMnemonicStep
            case .complete:
                completeStep
            case .error(let msg):
                errorStep(msg)
            }
        }
        .padding()
        .navigationTitle("Recovery Seed")
    }

    private var showMnemonicStep: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "key.horizontal.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.orange)

                Text("Write down these 12 words")
                    .font(.title2.bold())

                Text("These words are the only way to recover your account if you lose this device. Store them OFFLINE and never share them.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                wordsGrid

                Button("I've written them down") {
                    let hash = RecoverySeedViewModel.computeRecoveryHash(mnemonic: viewModel.mnemonicWords)
                    onConfirmSetup?(hash)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
    }

    private var wordsGrid: some View {
        let columns = [GridItem(.flexible()), GridItem(.flexible())]
        return LazyVGrid(columns: columns, spacing: 8) {
            ForEach(Array(viewModel.mnemonicWords.enumerated()), id: \.offset) { idx, word in
                HStack {
                    Text("\(idx + 1).")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .frame(width: 24, alignment: .leading)
                    Text(word)
                        .font(.body.monospaced().weight(.semibold))
                    Spacer()
                }
                .padding(8)
                .background(Color(.systemGray6))
                .cornerRadius(6)
            }
        }
    }

    private var enterMnemonicStep: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "rectangle.and.pencil.and.ellipsis")
                    .font(.system(size: 48))
                    .foregroundStyle(.blue)

                Text(headerForEnterStep)
                    .font(.title2.bold())

                Text("Enter all 12 words in order. Words must be lowercase.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                ForEach(0..<12, id: \.self) { idx in
                    HStack {
                        Text("\(idx + 1).")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .frame(width: 24, alignment: .leading)
                        TextField("word", text: bindingFor(idx))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding(6)
                            .background(Color(.systemGray6))
                            .cornerRadius(6)
                    }
                }

                Button(actionLabelForEnterStep) {
                    onVerifyMnemonic?(localTyped.map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(localTyped.contains(where: { $0.isEmpty }))
            }
        }
    }

    private var headerForEnterStep: String {
        switch viewModel.step {
        case .setupConfirmEntry: return "Confirm your mnemonic"
        case .verifyEnterMnemonic: return "Restore from recovery phrase"
        default: return ""
        }
    }

    private var actionLabelForEnterStep: String {
        switch viewModel.step {
        case .setupConfirmEntry: return "Confirm"
        case .verifyEnterMnemonic: return "Restore account"
        default: return ""
        }
    }

    private func bindingFor(_ idx: Int) -> Binding<String> {
        Binding(
            get: {
                guard idx < self.localTyped.count else { return "" }
                return self.localTyped[idx]
            },
            set: { newValue in
                if idx >= self.localTyped.count {
                    while self.localTyped.count <= idx { self.localTyped.append("") }
                }
                self.localTyped[idx] = newValue
            }
        )
    }

    private var completeStep: some View {
        VStack(spacing: 24) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)
            Text("Done").font(.title.bold())
            Text("Your recovery phrase is enrolled. Keep it safe.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Done", action: { onDismiss?() })
                .buttonStyle(.borderedProminent)
        }
    }

    private func errorStep(_ msg: String) -> some View {
        VStack(spacing: 24) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.red)
            Text("Recovery error").font(.title.bold())
            Text(msg)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Try again", action: { onDismiss?() })
                .buttonStyle(.bordered)
        }
    }
}

#Preview("Show mnemonic") {
    NavigationStack { RecoverySeedView() }
}
