import SwiftUI
import QAudionEngine

/// What the root view adds for the device-approval flow:
///  - the sheet where this device answers a new sign-in (opened by the doorbell notice, a tap on its push or
///    the banner of the chat list);
///  - the prompt "Vuoi disconnettere gli altri dispositivi?" after a sign-in that a device, a code or the
///    administrator approved on THIS device;
///  - the alert for the account notices that have a text only (denied, expired, recovered, disconnected,
///    recovery contact changed).
/// Each presentation hangs on its own invisible node, so none of them competes with the sheets the root
/// view already has.
struct DeviceApprovalRootModifier: ViewModifier {
    @ObservedObject var appState: AppState

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    Color.clear
                        .sheet(isPresented: $appState.showLoginApprovalSheet, onDismiss: {
                            appState.loginApproval.acknowledgeOutcome()
                        }) {
                            LoginApprovalSheet(model: appState.loginApproval) {
                                appState.showLoginApprovalSheet = false
                            }
                            .environmentObject(appState)
                        }
                    Color.clear
                        .sheet(isPresented: Binding(
                            get: { appState.pendingRevokePrompt != nil },
                            set: { if !$0 { appState.pendingRevokePrompt = nil } }
                        )) {
                            if let prompt = appState.pendingRevokePrompt {
                                DisconnectOthersSheet(initial: prompt) {
                                    appState.pendingRevokePrompt = nil
                                }
                                .environmentObject(appState)
                            }
                        }
                    Color.clear
                        .sheet(isPresented: $appState.showDeviceListFromNotice) {
                            DisconnectOthersSheet(initial: .keep, startInList: true) {
                                appState.showDeviceListFromNotice = false
                            }
                            .environmentObject(appState)
                        }
                    Color.clear
                        .alert(appState.accountNoticeToShow == .phoneMoved ? DeviceApprovalTexts.noticePhoneMovedTitle : DeviceApprovalTexts.noticeTitle, isPresented: Binding(
                            get: { appState.accountNoticeToShow != nil },
                            set: { if !$0 { appState.accountNoticeToShow = nil } }
                        )) {
                            if appState.accountNoticeToShow == .recoveryContactChanged {
                                Button(DeviceApprovalTexts.noticeOpenDevices) {
                                    appState.showDeviceListFromNotice = true
                                }
                            }
                            Button(DeviceApprovalTexts.noticeOk, role: .cancel) {}
                        } message: {
                            Text(Self.noticeText(appState.accountNoticeToShow))
                        }
                }
            }
    }

    static func noticeText(_ kind: AccountNoticeKind?) -> String {
        switch kind {
        case .loginDenied: return DeviceApprovalTexts.noticeLoginDenied
        case .loginExpired: return DeviceApprovalTexts.noticeLoginExpired
        case .loginRecovered: return DeviceApprovalTexts.noticeLoginRecovered
        case .deviceDisconnected: return DeviceApprovalTexts.noticeDeviceDisconnected
        case .recoveryContactChanged: return DeviceApprovalTexts.noticeRecoveryContactChanged
        case .phoneMoved: return DeviceApprovalTexts.noticePhoneMoved
        case .loginApprovalPending, .none: return ""
        }
    }
}

extension View {
    func deviceApprovalRoot(appState: AppState) -> some View {
        modifier(DeviceApprovalRootModifier(appState: appState))
    }
}

/// The question after an approved sign-in: disconnect every other device, pick them from the list of the
/// account, or keep them. The option selected when the sheet opens follows the server's `revoke_prompt`: after an
/// approval from a device it is "Mantieni", after a recovery by email, SMS or the administrator it is
/// "Disconnetti tutti". "Scegli" reads `GET /api/v1/account/devices` and shows one checkbox per OTHER device;
/// when the list cannot be read the error is shown and "Mantieni" and "Disconnetti tutti" stay available.
struct DisconnectOthersSheet: View {
    let initial: RevokePrompt
    let onDone: () -> Void

    @EnvironmentObject private var appState: AppState
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType) private var type

    @State private var choice: DisconnectChoice
    @State private var busy = false
    @State private var failed = false
    @State private var listFailed = false
    @State private var picking = false
    @State private var devices: [AccountDevice] = []
    @State private var selected: Set<String> = []

    /// `startInList`: open straight on the list of devices (the "recovery contact changed" notice), where a
    /// device that did not change it can be disconnected.
    private let startInList: Bool

    init(initial: RevokePrompt, startInList: Bool = false, onDone: @escaping () -> Void) {
        self.initial = initial
        self.startInList = startInList
        self.onDone = onDone
        _choice = State(initialValue: DisconnectPrompt.defaultChoice(for: initial))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                scheme.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if picking {
                            pickingContent
                        } else {
                            questionContent
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 24)
                }
            }
            .task {
                guard startInList, !picking else { return }
                choice = .choose
                await apply()
            }
        }
    }

    // MARK: - Question

    @ViewBuilder
    private var questionContent: some View {
        Text(DeviceApprovalTexts.disconnectTitle)
            .qaudionStyle(type.titleLarge)
            .foregroundStyle(scheme.onSurface)
        Text(DeviceApprovalTexts.disconnectMessage)
            .qaudionStyle(type.bodyMedium)
            .foregroundStyle(scheme.onSurfaceVariant)
        option(.disconnectAll, DeviceApprovalTexts.disconnectAll, id: "disconnect-all")
        option(.choose, DeviceApprovalTexts.disconnectChoose, id: "disconnect-choose")
        option(.keep, DeviceApprovalTexts.disconnectKeep, id: "disconnect-keep")
        if listFailed {
            Text(DeviceApprovalTexts.disconnectListFailed)
                .qaudionStyle(type.bodySmall)
                .foregroundStyle(extras.riskHigh)
                .accessibilityIdentifier("disconnect-list-error")
        }
        if failed {
            Text(DeviceApprovalTexts.disconnectFailed)
                .qaudionStyle(type.bodySmall)
                .foregroundStyle(extras.riskHigh)
        }
        QAudionButton(action: { Task { await apply() } },
                      label: DeviceApprovalTexts.disconnectContinue,
                      variant: .primary,
                      loading: busy)
    }

    private func option(_ value: DisconnectChoice, _ title: String, id: String) -> some View {
        Button {
            choice = value
        } label: {
            HStack(spacing: 12) {
                Image(systemName: choice == value ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(scheme.primary)
                Text(title)
                    .qaudionStyle(type.bodyLarge)
                    .foregroundStyle(scheme.onSurface)
                Spacer()
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12).fill(scheme.surfaceVariant.opacity(choice == value ? 0.9 : 0.5)))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(choice == value ? .isSelected : [])
        .accessibilityIdentifier(id)
    }

    // MARK: - Picking

    @ViewBuilder
    private var pickingContent: some View {
        Text(DeviceApprovalTexts.disconnectPickTitle)
            .qaudionStyle(type.titleLarge)
            .foregroundStyle(scheme.onSurface)
        if !devices.contains(where: { !$0.current }) {
            Text(DeviceApprovalTexts.disconnectPickNone)
                .qaudionStyle(type.bodyMedium)
                .foregroundStyle(scheme.onSurfaceVariant)
        }
        ForEach(devices) { device in
            deviceRow(device)
        }
        if failed {
            Text(DeviceApprovalTexts.disconnectPickFailed)
                .qaudionStyle(type.bodySmall)
                .foregroundStyle(extras.riskHigh)
        }
        QAudionButton(action: { Task { await disconnectSelected() } },
                      label: DeviceApprovalTexts.disconnectPickConfirm,
                      variant: .primary,
                      loading: busy)
            .disabled(selected.isEmpty || busy)
            .accessibilityIdentifier("disconnect-pick-confirm")
        Button {
            picking = false
            failed = false
        } label: {
            Text(DeviceApprovalTexts.disconnectPickBack)
                .qaudionStyle(type.bodyLarge)
                .foregroundStyle(scheme.primary)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .disabled(busy)
        .accessibilityIdentifier("disconnect-pick-back")
    }

    private func deviceRow(_ device: AccountDevice) -> some View {
        let isOn = selected.contains(device.deviceId)
        return Button {
            guard !device.current else { return }
            if isOn { selected.remove(device.deviceId) } else { selected.insert(device.deviceId) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: device.current ? "checkmark.circle.fill" : (isOn ? "checkmark.square.fill" : "square"))
                    .foregroundStyle(device.current ? scheme.onSurfaceVariant : scheme.primary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.label.isEmpty ? device.platform : device.label)
                        .qaudionStyle(type.bodyLarge)
                        .foregroundStyle(scheme.onSurface)
                    Text(device.current ? DeviceApprovalTexts.disconnectPickCurrent : device.platform)
                        .qaudionStyle(type.bodySmall)
                        .foregroundStyle(scheme.onSurfaceVariant)
                }
                Spacer()
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12).fill(scheme.surfaceVariant.opacity(device.current ? 0.3 : (isOn ? 0.9 : 0.5))))
        }
        .buttonStyle(.plain)
        .disabled(device.current)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier("disconnect-device-\(device.deviceId)")
    }

    // MARK: - Actions

    @MainActor
    private func apply() async {
        failed = false
        listFailed = false
        switch choice {
        case .keep:
            onDone()
        case .choose:
            busy = true
            defer { busy = false }
            do {
                devices = try await appState.loginApprovalApi.listDevices()
                selected = []
                picking = true
            } catch {
                // The question stays as it is: "Mantieni" and "Disconnetti tutti" remain available.
                listFailed = true
            }
        case .disconnectAll:
            busy = true
            defer { busy = false }
            do {
                // The signature needs the device key on the server; the question was held back until it
                // was published, this repeats the call in case that first attempt failed.
                await appState.ensureDeviceKeyPublished()
                let fresh = try await appState.loginApprovalApi.revokeOthers()
                appState.adoptRevokeOthersSession(fresh)
                onDone()
            } catch {
                failed = true
            }
        }
    }

    @MainActor
    private func disconnectSelected() async {
        failed = false
        busy = true
        defer { busy = false }
        var anyFailed = false
        for device in devices.filter({ selected.contains($0.deviceId) && !$0.current }) {
            do {
                try await appState.loginApprovalApi.revokeDevice(id: device.deviceId)
                devices.removeAll { $0.deviceId == device.deviceId }
                selected.remove(device.deviceId)
            } catch {
                anyFailed = true
            }
        }
        if anyFailed {
            failed = true
        } else {
            onDone()
        }
    }
}
