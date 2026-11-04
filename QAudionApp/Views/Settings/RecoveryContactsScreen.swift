import SwiftUI
import QAudionEngine

/// Settings > Account > "Email e numero per il recupero". Both contacts are optional and never asked for
/// at sign-up: they only let the person approve a new sign-in with a code when the other device is gone.
/// Adding one sends a 6-digit code to it; the contact counts only after the code is entered. The server
/// shows a masked hint back, never the address or the number.
///
/// State is `RecoveryContactsModel`. Nothing typed here is logged.
struct RecoveryContactsScreen: View {
    @ObservedObject var model: RecoveryContactsModel

    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType) private var type

    @State private var emailInput = ""
    @State private var phoneInput = ""
    @State private var emailCode = ""
    @State private var phoneCode = ""
    @State private var confirmRemove: RecoveryContactKind?

    var body: some View {
        ZStack {
            scheme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(DeviceApprovalTexts.rcExplain)
                        .qaudionStyle(type.bodyMedium)
                        .foregroundStyle(scheme.onSurfaceVariant)
                    if model.loadFailed {
                        Text(DeviceApprovalTexts.rcLoadFailed)
                            .qaudionStyle(type.bodySmall)
                            .foregroundStyle(extras.riskHigh)
                    }
                    section(.email)
                    section(.phone)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 20)
            }
        }
        .navigationTitle(DeviceApprovalTexts.rcTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
        .confirmationDialog(DeviceApprovalTexts.rcRemoveConfirm,
                            isPresented: Binding(get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } }),
                            titleVisibility: .visible) {
            Button(DeviceApprovalTexts.rcRemove, role: .destructive) {
                if let kind = confirmRemove { Task { await model.remove(kind) } }
                confirmRemove = nil
            }
            Button(DeviceApprovalTexts.rcCancel, role: .cancel) { confirmRemove = nil }
        }
    }

    // MARK: - One contact

    private func section(_ kind: RecoveryContactKind) -> some View {
        let slot = model.slot(kind)
        return VStack(alignment: .leading, spacing: 10) {
            Text(kind == .email ? DeviceApprovalTexts.rcEmail : DeviceApprovalTexts.rcPhone)
                .qaudionStyle(type.titleSmall)
                .foregroundStyle(scheme.primary)

            statusLine(slot)

            switch slot.step {
            case .awaitingCode, .verifying:
                codeEntry(kind, slot: slot)
            case .idle, .sending, .removing:
                valueEntry(kind, slot: slot)
            }

            if let problem = slot.problem {
                Text(Self.text(for: problem))
                    .qaudionStyle(type.bodySmall)
                    .foregroundStyle(extras.riskHigh)
                    .accessibilityIdentifier("recovery-\(kind.rawValue)-error")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(scheme.surfaceVariant.opacity(0.6)))
    }

    private func statusLine(_ slot: RecoveryContactsModel.Slot) -> some View {
        HStack(spacing: 8) {
            if let masked = slot.masked {
                Text(masked)
                    .qaudionStyle(type.bodyMedium)
                    .foregroundStyle(scheme.onSurface)
                Text(slot.verified ? DeviceApprovalTexts.rcVerified : DeviceApprovalTexts.rcUnverified)
                    .qaudionStyle(type.labelMedium)
                    .foregroundStyle(slot.verified ? extras.riskLow : extras.warning)
            } else {
                Text(DeviceApprovalTexts.rcNotSet)
                    .qaudionStyle(type.bodyMedium)
                    .foregroundStyle(scheme.onSurfaceVariant)
            }
        }
    }

    private func valueEntry(_ kind: RecoveryContactKind, slot: RecoveryContactsModel.Slot) -> some View {
        let input = kind == .email ? $emailInput : $phoneInput
        let busy = slot.step == .sending || slot.step == .removing
        return VStack(alignment: .leading, spacing: 10) {
            TextField(kind == .email ? DeviceApprovalTexts.rcEmailPlaceholder : DeviceApprovalTexts.rcPhonePlaceholder,
                      text: input)
                .keyboardType(kind == .email ? .emailAddress : .phonePad)
                .textContentType(kind == .email ? .emailAddress : .telephoneNumber)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .foregroundStyle(scheme.onSurface)
                .padding(14)
                .background(fieldBorder)
                .accessibilityIdentifier("recovery-\(kind.rawValue)-field")
            HStack(spacing: 12) {
                QAudionButton(
                    action: { Task { await model.start(kind, value: Self.normalised(kind, input.wrappedValue)) } },
                    label: slot.masked == nil ? DeviceApprovalTexts.rcAdd : DeviceApprovalTexts.rcChange,
                    variant: .secondary,
                    loading: slot.step == .sending,
                    enabled: !input.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty && !busy)
                if slot.masked != nil {
                    QAudionButton(action: { confirmRemove = kind },
                                  label: DeviceApprovalTexts.rcRemove,
                                  variant: .text,
                                  loading: slot.step == .removing,
                                  enabled: !busy)
                }
            }
        }
    }

    private func codeEntry(_ kind: RecoveryContactKind, slot: RecoveryContactsModel.Slot) -> some View {
        let code = kind == .email ? $emailCode : $phoneCode
        return VStack(alignment: .leading, spacing: 10) {
            Text(DeviceApprovalTexts.rcCodeSent)
                .qaudionStyle(type.bodySmall)
                .foregroundStyle(scheme.onSurfaceVariant)
            TextField(DeviceApprovalTexts.rcCodePlaceholder, text: code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .foregroundStyle(scheme.onSurface)
                .padding(14)
                .background(fieldBorder)
                .onChange(of: code.wrappedValue) { value in
                    let digits = String(value.filter { $0.isASCII && $0.isNumber }.prefix(6))
                    if digits != value { code.wrappedValue = digits }
                }
                .accessibilityIdentifier("recovery-\(kind.rawValue)-code-field")
            HStack(spacing: 12) {
                QAudionButton(action: { Task { await model.verify(kind, code: code.wrappedValue) } },
                              label: DeviceApprovalTexts.rcVerify,
                              variant: .primary,
                              loading: slot.step == .verifying,
                              enabled: code.wrappedValue.count == 6 && slot.step != .verifying)
                QAudionButton(action: {
                    code.wrappedValue = ""
                    model.cancelCode(kind)
                }, label: DeviceApprovalTexts.rcCancel, variant: .text, enabled: slot.step != .verifying)
            }
        }
    }

    private var fieldBorder: some View {
        RoundedRectangle(cornerRadius: 12)
            .stroke(scheme.onSurfaceVariant.opacity(0.4), lineWidth: 1)
    }

    // MARK: - Helpers

    /// The phone number is sent in international format without the spaces and dashes people type.
    static func normalised(_ kind: RecoveryContactKind, _ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard kind == .phone else { return trimmed }
        return trimmed.filter { $0 == "+" || ($0.isASCII && $0.isNumber) }
    }

    static func text(for problem: RecoveryContactsModel.Problem) -> String {
        switch problem {
        case .invalidValue: return DeviceApprovalTexts.rcErrorInvalidValue
        case .invalidCode: return DeviceApprovalTexts.rcErrorInvalidCode
        case .rateLimited: return DeviceApprovalTexts.rcErrorRateLimited
        case .clockWrong: return DeviceApprovalTexts.rcErrorClock
        case .failed: return DeviceApprovalTexts.rcErrorFailed
        }
    }
}
