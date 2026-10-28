import SwiftUI
import QAudionEngine

/// Settings > Account > "Recedi dal contratto qui": the text of art. 7.7 (from the server), then "Conferma recesso".
/// On a receipt the account is already deleted on the server; the phone is wiped at once and the receipt screen is
/// shown above the rest of the app until the person has saved or shared it.
struct WithdrawalScreen: View {
    let appState: AppState
    @StateObject private var model: WithdrawalModel
    @State private var info: String?
    @State private var infoFailed = false

    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType) private var type

    init(appState: AppState) {
        self.appState = appState
        _model = StateObject(wrappedValue: WithdrawalModel(
            api: AppStateLegalApi(appState: appState),
            onReceipt: { [weak appState] receipt in
                WithdrawalReceiptStore.shared.present(receipt)
                appState?.finishLocalSessionAfterServerSideDeletion()
            }))
    }

    var body: some View {
        ZStack {
            scheme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    infoSection
                    Text(verbatim: LegalStrings.withdrawWarning)
                        .qaudionStyle(type.bodySmall)
                        .foregroundStyle(scheme.onSurface)
                    stateSection
                    confirmButton
                }
                .padding(16)
                .qaudionReadableWidth()
            }
        }
        .navigationTitle(Text(verbatim: LegalStrings.withdrawTitle))
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadInfo() }
    }

    @ViewBuilder
    private var infoSection: some View {
        if let info {
            Text(verbatim: info)
                .qaudionStyle(type.bodySmall)
                .foregroundStyle(scheme.onSurfaceVariant)
        } else if infoFailed {
            Button {
                Task { await loadInfo() }
            } label: {
                Text(verbatim: LegalStrings.loadFailed + " " + LegalStrings.retry)
                    .qaudionStyle(type.labelSmall)
                    .foregroundStyle(scheme.primary)
            }
            .buttonStyle(.plain)
        } else {
            ProgressView()
        }
    }

    @ViewBuilder
    private var stateSection: some View {
        switch model.state {
        case .sending:
            HStack(spacing: 8) {
                ProgressView()
                Text(verbatim: LegalStrings.withdrawSending)
                    .qaudionStyle(type.labelSmall)
                    .foregroundStyle(scheme.onSurfaceVariant)
            }
        case .failed(.network):
            Text(verbatim: LegalStrings.withdrawFailed)
                .qaudionStyle(type.labelSmall)
                .foregroundStyle(extras.riskHigh)
        case .failed(.sessionEnded):
            Text(verbatim: LegalStrings.withdrawSessionEnded)
                .qaudionStyle(type.labelSmall)
                .foregroundStyle(extras.riskHigh)
        case .info, .receipt:
            EmptyView()
        }
    }

    private var confirmButton: some View {
        Button {
            Task { await model.confirm() }
        } label: {
            Text(verbatim: LegalStrings.withdrawConfirm)
                .qaudionStyle(type.bodyMedium)
                .foregroundStyle(extras.riskHigh)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(RoundedRectangle(cornerRadius: 12).fill(extras.riskHigh.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .disabled(!model.canConfirm)
        .accessibilityIdentifier("withdraw-confirm")
    }

    private func loadInfo() async {
        infoFailed = false
        do {
            let fetch = try await AppStateLegalApi(appState: appState).fetchTerms(lang: LegalService.documentLanguage)
            info = fetch.document.withdrawalInfo
        } catch {
            infoFailed = true
        }
    }
}

/// The receipt of the withdrawal, with Save (Files) and Share (the system sheet, a text file). Above the rest of the
/// app: by the time it shows, the account is gone.
struct WithdrawalReceiptScreen: View {
    let receipt: WithdrawalReceipt
    let onClose: () -> Void

    @State private var exporting = false
    @State private var shareURL: URL?
    @State private var saved = false
    @State private var askingToSave = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 12) {
                Text(verbatim: LegalStrings.receiptTitle)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                Text(verbatim: LegalStrings.receiptKeep)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.75))
                ScrollView {
                    Text(verbatim: receipt.receiptText)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(12)
                }
                .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.06)))
                HStack(spacing: 12) {
                    Button {
                        exporting = true
                    } label: {
                        Label {
                            Text(verbatim: LegalStrings.receiptSave)
                        } icon: {
                            Image(systemName: "square.and.arrow.down")
                        }
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .foregroundStyle(.black)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .accessibilityIdentifier("receipt-save")
                    if let shareURL {
                        ShareLink(item: shareURL) {
                            Label {
                                Text(verbatim: LegalStrings.receiptShare)
                            } icon: {
                                Image(systemName: "square.and.arrow.up")
                            }
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .foregroundStyle(.black)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .accessibilityIdentifier("receipt-share")
                        // The share sheet is the person's own way of keeping it: no question when closing after it.
                        .simultaneousGesture(TapGesture().onEnded { saved = true })
                    }
                }
                Button {
                    switch ReceiptClosePolicy.decide(saved: saved) {
                    case .close: onClose()
                    case .askToSave: askingToSave = true
                    }
                } label: {
                    Text("Chiudi")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .foregroundStyle(.white)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.4), lineWidth: 1.2))
                }
                .accessibilityIdentifier("receipt-close")
            }
            .padding(20)
            .qaudionReadableWidth()
        }
        .preferredColorScheme(.dark)
        .alert(LegalStrings.receiptUnsavedTitle, isPresented: $askingToSave) {
            Button(LegalStrings.receiptSave) { exporting = true }
            Button(LegalStrings.receiptCloseAnyway, role: .destructive, action: onClose)
        } message: {
            Text(verbatim: LegalStrings.receiptUnsavedMessage)
        }
        .onAppear { shareURL = ReceiptFile.writeTemporary(receipt) }
        .onDisappear {
            if let shareURL { try? FileManager.default.removeItem(at: shareURL) }
        }
        .fileExporter(
            isPresented: $exporting,
            document: ReceiptTextDocument(text: receipt.receiptText),
            contentType: .plainText,
            defaultFilename: ReceiptFile.fileName(receiptId: receipt.receiptId).replacingOccurrences(of: ".txt", with: ""),
            onCompletion: { result in
                if case .success = result {
                    saved = true
                    WithdrawalReceiptStore.shared.savedToFiles()
                }
            })
    }
}
