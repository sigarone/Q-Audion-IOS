import SwiftUI
import QAudionEngine

/// Shown over the extension sign-in form after the server answered "another device must approve this one".
///
/// The new device shows a big two-digit number; the person picks the same number on an already approved
/// device. Meanwhile `LoginWaitModel` polls every 3 s. When the other device is gone, a code by email or SMS
/// (only offered for a verified recovery contact) or the 8-character code for the administrator is the way
/// out. Denied, expired and revoked end here with a text and a way back to the form.
///
/// Nothing shown here is logged: not the number, not the codes, not the hints.
struct LoginApprovalWaitView: View {
    @StateObject private var model: LoginWaitModel
    let onApproved: (ApprovedLogin) -> Void
    let onBack: () -> Void

    @State private var code = ""
    @FocusState private var codeFocused: Bool

    init(ticket: PendingLoginTicket, api: PendingLoginApi,
         onApproved: @escaping (ApprovedLogin) -> Void, onBack: @escaping () -> Void) {
        _model = StateObject(wrappedValue: LoginWaitModel(ticket: ticket, api: api))
        self.onApproved = onApproved
        self.onBack = onBack
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch model.phase {
                    case .waiting, .approved:
                        waitingContent
                    case .denied:
                        endContent(title: DeviceApprovalTexts.waitDeniedTitle, text: DeviceApprovalTexts.waitDeniedText)
                    case .expired:
                        endContent(title: DeviceApprovalTexts.waitExpiredTitle, text: DeviceApprovalTexts.waitExpiredText)
                    case .sessionRevoked:
                        endContent(title: DeviceApprovalTexts.waitRevokedTitle, text: DeviceApprovalTexts.waitRevokedText)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 24)
                .qaudionReadableWidth()
            }
        }
        .task { model.start() }
        .onDisappear { model.stop() }
        .onChange(of: model.phase) { phase in
            guard phase == .approved, let approved = model.takeApproved() else { return }
            onApproved(approved)
        }
    }

    // MARK: - Waiting

    private var waitingContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(DeviceApprovalTexts.waitTitle)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)

            Text(model.ticket.matchCode)
                .font(.system(size: 88, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .accessibilityLabel(DeviceApprovalTexts.waitAccessibilityCode(model.ticket.matchCode))
                .accessibilityIdentifier("login-approval-match-code")

            Text(DeviceApprovalTexts.waitInstruction(model.ticket.matchCode))
                .font(.body)
                .foregroundStyle(.white.opacity(0.85))
                .frame(maxWidth: .infinity, alignment: .center)
                .multilineTextAlignment(.center)

            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(DeviceApprovalTexts.waitCountdown(Self.format(model.remainingSeconds(at: context.date))))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(maxWidth: .infinity)
            }

            HStack(spacing: 8) {
                ProgressView().tint(.white)
                Text(model.connectionProblem ? DeviceApprovalTexts.waitConnection : DeviceApprovalTexts.waitWaiting)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.7))
            }
            .frame(maxWidth: .infinity)

            recoverySection

            if !model.ticket.shortCode.isEmpty {
                Text(DeviceApprovalTexts.waitAdminHint(model.ticket.shortCode))
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.65))
                    .padding(.top, 8)
                    .accessibilityIdentifier("login-approval-admin-hint")
            }

            backButton
        }
    }

    // MARK: - Recovery by email or SMS

    @ViewBuilder
    private var recoverySection: some View {
        let ticket = model.ticket
        if ticket.emailRecovery || ticket.smsRecovery {
            VStack(alignment: .leading, spacing: 12) {
                // The email comes first: it is the quicker one when the person is at a computer.
                if ticket.emailRecovery {
                    channelButton(.email, label: DeviceApprovalTexts.waitEmailButton, hint: ticket.emailHint)
                }
                if ticket.smsRecovery {
                    channelButton(.sms, label: DeviceApprovalTexts.waitSmsButton, hint: ticket.phoneHint)
                }
                if let channel = codeChannel {
                    codeEntry(channel)
                }
                if let problem = model.recoveryProblem {
                    Text(Self.text(for: problem))
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("login-approval-recovery-error")
                }
            }
        }
    }

    private var codeChannel: RecoveryChannel? {
        switch model.recovery {
        case .codeSent(let channel), .verifying(let channel): return channel
        case .idle, .requesting: return nil
        }
    }

    private var busy: Bool {
        switch model.recovery {
        case .requesting, .verifying: return true
        case .idle, .codeSent: return false
        }
    }

    private func channelButton(_ channel: RecoveryChannel, label: String, hint: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                code = ""
                Task { await model.requestCode(channel) }
            } label: {
                HStack {
                    if model.recovery == .requesting(channel) { ProgressView().tint(.white) }
                    Text(label)
                        .font(.body.weight(.medium))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 48)
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.3), lineWidth: 1.2))
            }
            .disabled(busy)
            .accessibilityIdentifier(channel == .email ? "login-approval-email-button" : "login-approval-sms-button")
            if let hint, !hint.isEmpty {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.leading, 4)
            }
        }
    }

    private func codeEntry(_ channel: RecoveryChannel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(channel == .email ? DeviceApprovalTexts.waitCodeSentEmail : DeviceApprovalTexts.waitCodeSentSms)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.75))
            TextField(DeviceApprovalTexts.waitCodeField, text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .focused($codeFocused)
                .font(.title3.monospacedDigit())
                .foregroundStyle(.white)
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.3), lineWidth: 1.2))
                .onChange(of: code) { value in
                    let digits = String(value.filter { $0.isASCII && $0.isNumber }.prefix(6))
                    if digits != value { code = digits }
                }
                .accessibilityIdentifier("login-approval-code-field")
            Button {
                codeFocused = false
                Task { await model.verify(code: code) }
            } label: {
                HStack {
                    if case .verifying = model.recovery { ProgressView().tint(.black) }
                    Text(DeviceApprovalTexts.waitCodeConfirm).font(.body.weight(.semibold))
                }
                .frame(maxWidth: .infinity, minHeight: 52)
                .foregroundStyle(code.count == 6 ? .black : .white.opacity(0.4))
                .background(code.count == 6 ? Color.white : Color.white.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .disabled(code.count != 6 || busy)
            .accessibilityIdentifier("login-approval-code-confirm")
        }
    }

    // MARK: - Denied / expired

    private func endContent(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
            Text(text)
                .font(.body)
                .foregroundStyle(.white.opacity(0.8))
            backButton
        }
    }

    private var backButton: some View {
        Button(action: onBack) {
            Text(DeviceApprovalTexts.waitBack)
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 52)
                .foregroundStyle(.black)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .padding(.top, 8)
        .accessibilityIdentifier("login-approval-back")
    }

    // MARK: - Helpers

    static func format(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    static func text(for problem: LoginWaitModel.RecoveryProblem) -> String {
        switch problem {
        case .invalidCode: return DeviceApprovalTexts.waitErrorInvalidCode
        case .tooManyAttempts: return DeviceApprovalTexts.waitErrorTooMany
        case .codeExpired: return DeviceApprovalTexts.waitErrorCodeExpired
        case .rateLimited: return DeviceApprovalTexts.waitErrorRateLimited
        case .unavailable: return DeviceApprovalTexts.waitErrorUnavailable
        case .failed: return DeviceApprovalTexts.waitErrorFailed
        }
    }
}
