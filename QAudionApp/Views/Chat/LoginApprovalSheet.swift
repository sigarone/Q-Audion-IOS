import SwiftUI
import QAudionEngine

/// Sheet where an already approved device answers a new sign-in: it names the device, the system, the area
/// and the time, and shows three two-digit numbers. The right one is the number the new device shows; the
/// sheet never says which. Picking a wrong one makes the server deny the request for good. "Nega" denies it.
///
/// State is `LoginApprovalModel`; the signing with the device key happens in `BCryptoDeviceApprovalApi`.
struct LoginApprovalSheet: View {
    @ObservedObject var model: LoginApprovalModel
    let onClose: () -> Void

    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType) private var type

    var body: some View {
        ZStack {
            scheme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let result = finalOutcome {
                        resultContent(result)
                    } else if let request = model.current {
                        requestContent(request)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
            }
        }
        .onChange(of: model.current?.id) { id in
            // Nothing left to answer and nothing to tell: the sheet has no reason to stay.
            if id == nil, finalOutcome == nil { onClose() }
        }
        .onAppear {
            if model.current == nil, finalOutcome == nil { onClose() }
        }
    }

    /// The outcomes that end an entry. `.failed` keeps the entry on screen with a message instead.
    private var finalOutcome: LoginApprovalModel.Outcome? {
        guard let outcome = model.outcome, outcome != .failed else { return nil }
        return outcome
    }

    // MARK: - Request

    private func requestContent(_ request: LoginApprovalRequest) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(DeviceApprovalTexts.sheetTitle)
                .qaudionStyle(type.titleLarge)
                .foregroundStyle(scheme.onSurface)

            Text(DeviceApprovalTexts.sheetIntro)
                .qaudionStyle(type.bodyMedium)
                .foregroundStyle(scheme.onSurfaceVariant)

            VStack(alignment: .leading, spacing: 8) {
                row(DeviceApprovalTexts.sheetLabelDevice, request.deviceName)
                row(DeviceApprovalTexts.sheetLabelPlatform, request.platform)
                row(DeviceApprovalTexts.sheetLabelArea, request.area)
                if let createdAt = request.createdAt {
                    HStack(alignment: .firstTextBaseline) {
                        Text(DeviceApprovalTexts.sheetLabelTime)
                            .qaudionStyle(type.labelMedium)
                            .foregroundStyle(scheme.onSurfaceVariant)
                            .frame(width: 96, alignment: .leading)
                        Text(createdAt, style: .time)
                            .qaudionStyle(type.bodyMedium)
                            .foregroundStyle(scheme.onSurface)
                    }
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12).fill(scheme.surfaceVariant.opacity(0.6)))

            HStack(spacing: 12) {
                ForEach(request.choices, id: \.self) { choice in
                    Button {
                        Task { await model.approve(choice: choice) }
                    } label: {
                        Text(choice)
                            .font(.system(size: 36, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .frame(maxWidth: .infinity, minHeight: 84)
                            .foregroundStyle(scheme.onPrimary)
                            .background(RoundedRectangle(cornerRadius: 16).fill(scheme.primary))
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isBusy)
                    .accessibilityLabel(DeviceApprovalTexts.sheetChoiceAccessibility(choice))
                    .accessibilityIdentifier("login-approval-choice-\(choice)")
                }
            }
            .opacity(model.isBusy ? 0.5 : 1)

            if model.isBusy {
                ProgressView().frame(maxWidth: .infinity)
            }

            if model.outcome == .failed {
                Text(DeviceApprovalTexts.sheetFailed)
                    .qaudionStyle(type.bodySmall)
                    .foregroundStyle(extras.riskHigh)
            }

            Text(DeviceApprovalTexts.sheetWarning)
                .qaudionStyle(type.bodySmall)
                .foregroundStyle(scheme.onSurfaceVariant)

            HStack(spacing: 12) {
                QAudionButton(action: { Task { await model.deny() } },
                              label: DeviceApprovalTexts.sheetDeny,
                              variant: .destructive,
                              enabled: !model.isBusy)
                QAudionButton(action: onClose,
                              label: DeviceApprovalTexts.sheetClose,
                              variant: .text)
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .qaudionStyle(type.labelMedium)
                .foregroundStyle(scheme.onSurfaceVariant)
                .frame(width: 96, alignment: .leading)
            Text(value)
                .qaudionStyle(type.bodyMedium)
                .foregroundStyle(scheme.onSurface)
        }
    }

    // MARK: - Result

    private func resultContent(_ outcome: LoginApprovalModel.Outcome) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(DeviceApprovalTexts.sheetTitle)
                .qaudionStyle(type.titleLarge)
                .foregroundStyle(scheme.onSurface)
            Text(Self.text(for: outcome))
                .qaudionStyle(type.bodyMedium)
                .foregroundStyle(outcome == .wrongCode ? extras.riskHigh : scheme.onSurface)
                .accessibilityIdentifier("login-approval-result")
            QAudionButton(action: {
                model.acknowledgeOutcome()
                onClose()
            }, label: DeviceApprovalTexts.sheetClose, variant: .primary)
        }
    }

    static func text(for outcome: LoginApprovalModel.Outcome) -> String {
        switch outcome {
        case .approved: return DeviceApprovalTexts.sheetApproved
        case .denied: return DeviceApprovalTexts.sheetDenied
        case .wrongCode: return DeviceApprovalTexts.sheetWrongCode
        case .alreadyResolved: return DeviceApprovalTexts.sheetResolved
        case .failed: return DeviceApprovalTexts.sheetFailed
        }
    }
}

/// Banner on the chat list while a sign-in waits for this device: one line and a button that opens the sheet.
struct LoginApprovalBanner: View {
    @ObservedObject var model: LoginApprovalModel
    let onOpen: () -> Void

    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType) private var type

    var body: some View {
        if model.current != nil {
            HStack(spacing: 10) {
                Image(systemName: "iphone.badge.plus")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(extras.warning)
                Text(DeviceApprovalTexts.bannerTitle)
                    .qaudionStyle(type.labelLarge)
                    .foregroundStyle(scheme.onSurface)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: onOpen) {
                    Text(DeviceApprovalTexts.bannerOpen)
                        .qaudionStyle(type.labelLarge)
                        .foregroundStyle(scheme.primary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("login-approval-banner-open")
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 12).fill(extras.warning.opacity(0.18)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(extras.warning.opacity(0.45), lineWidth: 1))
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .accessibilityElement(children: .contain)
        }
    }
}
