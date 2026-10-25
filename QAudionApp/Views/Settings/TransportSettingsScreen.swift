import SwiftUI
import Combine
import QAudionEngine

@MainActor
final class TransportSettingsContainer: ObservableObject {
    @Published var viewModel: TransportSettingsViewModel
    @Published var diagnostics: TransportDiagnostics
    @Published var draftMode: TransportSettingsViewModel.Mode
    /// The custom TURN server, as three fields: the address (`turn:host:port`), the user name and the password. The
    /// password field is a secure field, and the three are saved apart (the address in UserDefaults, the user name and the
    /// password in the Keychain, see `TransportPreferences`).
    @Published var draftAddress: String { didSet { saveFailed = false } }
    @Published var draftUsername: String { didSet { saveFailed = false } }
    @Published var draftPassword: String { didSet { saveFailed = false } }
    /// What the calls use right now (`TransportGate`), what the last check ran with, and whether the user just saved: kept
    /// to tell the user when what is on the screen, or what was just checked, is not saved yet. The conditions of the two
    /// notes are the engine's `TransportSaveState`, where they are tested; this class only feeds it.
    @Published private(set) var saveState: TransportSaveState
    /// The last "Salva" did not take (the Keychain refused the user name and password): nothing was changed, and the fields
    /// keep what was typed. Cleared by the next edit of a field and by the next successful "Salva".
    @Published private(set) var saveFailed: Bool = false
    /// The whole check (server, relay list, mode) is running.
    @Published private(set) var isRunning: Bool = false
    /// `diagnostics` is a reference that never changes, so its own `@Published` values (server status, the mode check)
    /// would not redraw this screen by themselves; its `objectWillChange` is forwarded to the container's.
    private var diagnosticsForwarding: AnyCancellable?

    #if QAUDION_VPN
    // VPN exit-node picker. Reuses the same VpnService + access token the
    // HomeView VpnToggleChip uses, and the SAME `vpn.preferredNodeId`
    // UserDefaults key, so a choice made here and one made via the chip's
    // long-press picker stay in sync. Primitives/refs only (no AppState type
    // stored), so the build-landmine guard is not tripped.
    @Published var vpnNodes: [VpnNode] = []
    @Published var vpnNodesLoading = false
    private let vpnService: VpnService
    private let vpnTokenProvider: () -> String
    #endif

    init(state: AppState) {
        let stored = SettingsStore().loadTransport()
        // The screen shows what the calls really use (TransportGate), not the older copy kept in SettingsStore: the
        // two can differ for someone who saved a mode before the calls read it.
        let inUse = TransportGate.preferences
        let inUseMode = inUse.mode
        // The address as stored, usable or not: an address saved before the credentials were required reads as none for
        // the calls, but it is shown here so the note under the fields asks for them instead of dropping it silently. The
        // user name and the password come from the Keychain.
        let inUseAddress = inUse.storedAddressText
        let inUseCredentials = inUse.storedCredentials
        let diag = TransportDiagnostics(appState: state)
        self.viewModel = stored
        self.diagnostics = diag
        self.draftMode = inUseMode
        self.draftAddress = inUseAddress
        self.draftUsername = inUseCredentials?.username ?? ""
        self.draftPassword = inUseCredentials?.password ?? ""
        self.saveState = TransportSaveState(saved: TransportChoice(preferences: inUse))
        #if QAUDION_VPN
        self.vpnService = state.vpnService
        self.vpnTokenProvider = { state.currentAccessToken ?? "" }
        #endif
        self.diagnosticsForwarding = diag.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
    }

    // MARK: - Address

    /// What is on the screen: the mode of the picker and the three fields of the custom server.
    private var draftChoice: TransportChoice {
        TransportChoice(mode: draftMode, address: draftAddress, username: draftUsername, password: draftPassword)
    }

    /// The server typed in the fields, as a usable TURN server (`nil` when empty or not valid).
    private var draftCustomUrl: URL? { draftChoice.customTurnUrl }

    var addressState: TransportSettingsTexts.AddressState { draftChoice.addressState }

    /// The check result on the screen was made with the mode and the address that are saved (otherwise "Il controllo è
    /// stato fatto con una modalità o un indirizzo non ancora salvati").
    var checkIsSaved: Bool { saveState.checkMatchesSaved }

    /// "Salvato. Vale dalla prossima chiamata 1 a 1."
    var showSavedNote: Bool { saveState.showsSavedNote(draft: draftChoice) }

    #if QAUDION_VPN
    /// Fetch the live exit-node list (Helsinki, Milano, …) for the picker.
    /// Best-effort: a failure leaves the list empty (the row still shows
    /// "Auto"); never throws to the UI.
    func loadVpnNodes() async {
        let token = vpnTokenProvider()
        guard !token.isEmpty else { return }
        vpnNodesLoading = true
        defer { vpnNodesLoading = false }
        vpnNodes = (try? await vpnService.fetchNodes(accessToken: token)) ?? []
    }
    #endif

    /// The check button: the server, the relay list, and the mode that is selected in the picker (with the server
    /// typed in the fields, saved or not). An address that cannot be saved (not a TURN address, or without user name and
    /// password) is not tried: the note under the fields says so.
    func runDiagnostics() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        await diagnostics.checkServer()
        await diagnostics.fetchTurnRelays()
        guard !addressState.blocksSaving else { return }
        let mode = draftMode
        let url = draftCustomUrl
        saveState.recordCheck(draftChoice)
        await diagnostics.checkMode(mode, customTurnUrl: url)
    }

    /// Saves the mode and the server for the calls: the address goes to UserDefaults, the user name and the password to the
    /// Keychain. An address that is not a usable TURN address (not valid, or without user name and password) is not saved:
    /// the refusal is the engine's (`TransportSaveState.save`, pinned by `TransportChoiceTests`), the button is disabled
    /// for it too.
    ///
    /// When the Keychain refuses the credentials nothing is changed (`TransportPreferences.save`): the storage read back is
    /// not what is on the screen, the fields keep what was typed, and a message says so.
    func save() {
        var state = saveState
        let didSave = state.save(
            draft: draftChoice,
            // Whether the Keychain took the credentials is not asked here: the read back below tells.
            write: { choice in
                _ = diagnostics.saveTransport(mode: choice.mode, preferredUrl: choice.customTurnUrl)
            },
            // "Salvato" is about what the calls will read, so it is taken back from the storage, not from the draft.
            readBack: { TransportChoice(preferences: TransportGate.preferences) })
        guard didSave else { return }
        saveState = state
        viewModel = SettingsStore().loadTransport()
        guard draftChoice.isSaved(as: saveState.saved) else {
            saveFailed = true
            return
        }
        // The fields show what the storage holds (the normalised address), the password still hidden in its field.
        draftAddress = saveState.saved.addressField
        draftUsername = saveState.saved.usernameField
        draftPassword = saveState.saved.passwordField
        saveFailed = false
    }
}

// MARK: - Status helpers

private extension TransportDiagnostics.ConnectionStatus {
    func tone(extras: QAudionColorsExtra) -> Color {
        switch self {
        case .unknown:     return Color.gray
        case .healthy:     return extras.success
        case .degraded:    return extras.warning
        case .unreachable: return extras.riskHigh
        }
    }

    var label: String {
        switch self {
        case .unknown:                    return String(localized: "Sconosciuto")
        case .healthy(let ms):            return String(localized: "settings.transport.status.healthy", defaultValue: "Operativo (\(ms) ms)", comment: "Transport settings, server status value: reachable; placeholder is the round-trip time in milliseconds")
        case .degraded(let ms):           return String(localized: "settings.transport.status.degraded", defaultValue: "Degradato (\(ms) ms)", comment: "Transport settings, server status value: reachable but slow; placeholder is the round-trip time in milliseconds")
        case .unreachable:                return String(localized: "settings.transport.status.unreachable", defaultValue: "Non raggiungibile", comment: "Transport settings, server status value: the server cannot be reached")
        }
    }
}

private extension TransportSettingsViewModel.Mode {
    var localizedLabel: String {
        switch self {
        case .auto:  return "Auto"
        case .p2p:   return "P2P"
        case .turn:  return "TURN"
        case .relay: return "Relay"
        }
    }
}

// MARK: - Screen

/// Transport settings sub-screen. W31 design-token refactor.
/// Replaces stock `Form` with the new design vocabulary.
struct TransportSettingsScreen: View {
    @StateObject private var container: TransportSettingsContainer

    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType) private var type

    #if QAUDION_VPN
    /// Manual VPN exit choice. '' = Auto (NodePicker best). SAME UserDefaults
    /// key as the HomeView VpnToggleChip long-press picker, so both stay in sync.
    @AppStorage("vpn.preferredNodeId") private var preferredVpnNodeId: String = ""
    #endif

    init(state: AppState) {
        _container = StateObject(wrappedValue: TransportSettingsContainer(state: state))
    }

    var body: some View {
        ZStack {
            scheme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SettingsSectionHeader("MODALITÀ DI CONNESSIONE")
                    modePicker
                    Text(TransportSettingsTexts.explanation(for: container.draftMode, address: container.addressState))
                        .qaudionStyle(type.labelSmall)
                        .foregroundStyle(scheme.onSurfaceVariant)
                        .padding(.horizontal, 14)
                        .padding(.top, 6)

                    #if QAUDION_VPN
                    SettingsSectionHeader("NODO VPN (USCITA)")
                    vpnNodeSection
                    #endif

                    SettingsSectionHeader("SERVER TURN")
                    turnInputRow
                    Text(TransportSettingsTexts.addressNote(mode: container.draftMode, address: container.addressState))
                        .qaudionStyle(type.labelSmall)
                        .foregroundStyle(container.addressState.blocksSaving ? extras.riskHigh : scheme.onSurfaceVariant)
                        .padding(.horizontal, 14).padding(.top, 6)

                    SettingsSectionHeader("DIAGNOSTICA")
                    VStack(spacing: 8) {
                        // W-L10N-BATCH1 (2026-09-08) — statusRow's
                        // `label:` is a plain String, not
                        // LocalizedStringKey (see its signature below),
                        // so this literal doesn't auto-localize.
                        // `value:` is `container.diagnostics.
                        // serverStatus.label`, a live diagnostic result
                        // (not a call-site literal) — left untouched.
                        statusRow(label: String(localized: "transport_settings.status.server_label", defaultValue: "Stato server", comment: "Transport settings, DIAGNOSTICA section — status row label for the server connectivity check"),
                                  value: container.diagnostics.serverStatus.label,
                                  tone: container.diagnostics.serverStatus.tone(extras: extras))
                        kvRow(label: TransportSettingsTexts.relayListResponseTitle,
                              value: millisecondsText(container.diagnostics.lastTurnRoundTripMs),
                              mono: true)
                        kvRow(label: TransportSettingsTexts.relayListResponseSavedTitle,
                              value: millisecondsText(container.viewModel.lastTurnRoundTripMs),
                              mono: true)
                        if let lastChecked = container.diagnostics.lastChecked {
                            kvRow(label: "Ultimo controllo",
                                  value: lastChecked.formatted(Date.FormatStyle(date: .omitted, time: .standard).locale(Locale(identifier: AppLanguageManager.effectiveLanguageCode))),
                                  mono: true)
                        }
                        if let errMsg = container.diagnostics.errorMessage {
                            errorBanner(errMsg)
                        }
                        runCheckButton
                        modeCheckSection
                    }

                    Spacer().frame(height: 16)
                    saveButton
                    if container.showSavedNote {
                        Text(TransportSettingsTexts.savedText)
                            .qaudionStyle(type.labelSmall)
                            .foregroundStyle(extras.success)
                            .padding(.horizontal, 14).padding(.top, 8)
                    }
                    if container.saveFailed {
                        errorBanner(TransportSettingsTexts.saveFailedText)
                            .padding(.top, 8)
                    }
                    Spacer().frame(height: 24)
                }
                .padding(.horizontal, 16)
            }
        }
        .navigationTitle("Trasporto")
        #if QAUDION_VPN
        .task { await container.loadVpnNodes() }
        #endif
    }

    // MARK: - Mode picker

    private var modePicker: some View {
        Picker("", selection: $container.draftMode) {
            ForEach(TransportSettingsViewModel.Mode.allCases, id: \.self) { mode in
                Text(mode.localizedLabel).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(scheme.surfaceVariant.opacity(0.4))
        )
    }

    #if QAUDION_VPN
    // MARK: - VPN exit node

    @ViewBuilder
    private var vpnNodeSection: some View {
        VStack(spacing: 8) {
            vpnNodeRow(id: "", title: String(localized: "Auto"), subtitle: String(localized: "settings.transport.vpn.auto_subtitle", defaultValue: "Nodo migliore · latenza + carico", comment: "Transport settings, VPN exit node list: subtitle of the automatic choice"))
            ForEach(container.vpnNodes) { n in
                let loadPct: Int = Int((n.loadPct * 100).rounded())
                let sub: String = String(localized: "settings.transport.vpn.node_load", defaultValue: "\(n.country) · \(loadPct)% carico", comment: "Transport settings, VPN exit node row subtitle: country and server load percentage; placeholders are the country and the number")
                let ttl: String = n.city.isEmpty ? n.id : n.city
                vpnNodeRow(id: n.id, title: ttl, subtitle: sub)
            }
            if container.vpnNodesLoading && container.vpnNodes.isEmpty {
                Text("Caricamento nodi…")
                    .qaudionStyle(type.labelSmall)
                    .foregroundStyle(scheme.onSurfaceVariant)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
            }
        }
        Text("Scegli da quale paese esce il traffico VPN. \"Auto\" sceglie il nodo migliore. La scelta vale dalla prossima connessione VPN.")
            .qaudionStyle(type.labelSmall)
            .foregroundStyle(scheme.onSurfaceVariant)
            .padding(.horizontal, 14).padding(.top, 6)
    }

    private func vpnNodeRow(id: String, title: String, subtitle: String) -> some View {
        Button {
            preferredVpnNodeId = id
        } label: {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .qaudionStyle(type.bodyMedium)
                        .foregroundStyle(scheme.onSurface)
                    Text(subtitle)
                        .qaudionStyle(type.labelSmall)
                        .foregroundStyle(scheme.onSurfaceVariant)
                }
                Spacer()
                if preferredVpnNodeId == id {
                    Image(systemName: "checkmark")
                        .foregroundStyle(extras.success)
                }
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 52)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(scheme.surfaceVariant.opacity(0.4))
            )
        }
        .buttonStyle(.plain)
    }
    #endif

    // MARK: - TURN server input

    /// The three fields of the custom server: the address, the user name and the password. The password is a secure field
    /// (its text is masked), and none of the three asks the system to offer or save a login: the password is kept by
    /// `TransportPreferences` in the Keychain of this phone only.
    private var turnInputRow: some View {
        VStack(spacing: 8) {
            turnFieldRow(icon: "antenna.radiowaves.left.and.right") {
                TextField("", text: $container.draftAddress,
                          prompt: Text("turn:hostname:3478")
                              .foregroundColor(scheme.onSurfaceVariant))
                    .qaudionStyle(type.bodyMedium)
                    .foregroundColor(scheme.onSurface)
                    .tint(scheme.primary)
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
            }
            turnFieldRow(icon: "person") {
                TextField("", text: $container.draftUsername,
                          prompt: Text(TransportSettingsTexts.usernameFieldTitle)
                              .foregroundColor(scheme.onSurfaceVariant))
                    .qaudionStyle(type.bodyMedium)
                    .foregroundColor(scheme.onSurface)
                    .tint(scheme.primary)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .accessibilityLabel(TransportSettingsTexts.usernameFieldTitle)
            }
            turnFieldRow(icon: "lock") {
                SecureField("", text: $container.draftPassword,
                            prompt: Text(TransportSettingsTexts.passwordFieldTitle)
                                .foregroundColor(scheme.onSurfaceVariant))
                    .qaudionStyle(type.bodyMedium)
                    .foregroundColor(scheme.onSurface)
                    .tint(scheme.primary)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .accessibilityLabel(TransportSettingsTexts.passwordFieldTitle)
            }
        }
    }

    private func turnFieldRow<Field: View>(icon: String, @ViewBuilder field: () -> Field) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(scheme.onSurfaceVariant)
                .frame(width: 22)

            field()
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 56)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(scheme.surfaceVariant.opacity(0.4))
        )
    }

    // MARK: - Diagnostic rows

    private func statusRow(label: String, value: String, tone: Color) -> some View {
        HStack(spacing: 14) {
            Text(label)
                .qaudionStyle(type.bodyMedium)
                .foregroundStyle(scheme.onSurface)
            Spacer()
            HStack(spacing: 6) {
                Circle().fill(tone).frame(width: 8, height: 8)
                Text(value)
                    .qaudionStyle(type.labelSmall)
                    .foregroundStyle(tone)
                    .modifier(MonoIfNeededT(mono: true))
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 52)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(scheme.surfaceVariant.opacity(0.4))
        )
    }

    /// Literal label: looked up in the string catalog.
    private func kvRow(label: LocalizedStringKey, value: String, mono: Bool) -> some View {
        kvRowContent(label: Text(label), value: value, mono: mono)
    }

    /// Already-resolved label: shown as is, never parsed as a key or Markdown.
    @_disfavoredOverload
    private func kvRow(label: String, value: String, mono: Bool) -> some View {
        kvRowContent(label: Text(verbatim: label), value: value, mono: mono)
    }

    private func kvRowContent(label: Text, value: String, mono: Bool) -> some View {
        HStack(spacing: 14) {
            label
                .qaudionStyle(type.bodyMedium)
                .foregroundStyle(scheme.onSurface)
            Spacer()
            Text(value)
                .qaudionStyle(type.labelSmall)
                .foregroundStyle(scheme.onSurfaceVariant)
                .modifier(MonoIfNeededT(mono: mono))
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 52)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(scheme.surfaceVariant.opacity(0.4))
        )
    }

    private func errorBanner(_ msg: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(extras.riskHigh)
                .padding(.top, 1)
            Text(msg)
                .qaudionStyle(type.labelSmall)
                .foregroundStyle(extras.riskHigh)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(extras.riskHigh.opacity(0.12))
        )
    }

    // MARK: - Buttons

    private var runCheckButton: some View {
        Button {
            Task { await container.runDiagnostics() }
        } label: {
            HStack {
                if container.isRunning {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(0.8)
                        .tint(scheme.onSurface)
                }
                Text(TransportSettingsTexts.checkButtonTitle(running: container.isRunning))
                    .qaudionStyle(type.labelLarge)
                    .foregroundStyle(scheme.onSurface)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(scheme.surfaceVariant.opacity(0.4))
            )
        }
        .buttonStyle(.plain)
        .disabled(container.isRunning)
    }

    private var saveButton: some View {
        Button { container.save() } label: {
            Text("Salva")
                .qaudionStyle(type.labelLarge)
                .tracking(0.8)
                .foregroundStyle(scheme.onPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 24)
                        .fill(scheme.primary)
                )
        }
        .buttonStyle(.plain)
        .disabled(container.addressState.blocksSaving)
        .opacity(container.addressState.blocksSaving ? 0.4 : 1)
    }

    // MARK: - Mode check result

    /// What the check found for the selected mode, then the two answers the user can give: "Confermo" and
    /// "Segnala problema". The last confirmation (mode and date) stays visible below.
    @ViewBuilder
    private var modeCheckSection: some View {
        if case .finished(let result) = container.diagnostics.modeCheck {
            VStack(spacing: 8) {
                stackedRow(label: TransportSettingsTexts.rowModeTitle, value: result.plan.mode.localizedLabel)
                stackedRow(label: TransportSettingsTexts.rowRouteTitle,
                           value: TransportSettingsTexts.routeText(result.plan.route))
                stackedRow(label: TransportSettingsTexts.rowCandidatesTitle,
                           value: TransportSettingsTexts.candidatesText(result.counts))
                outcomeBanner(TransportSettingsTexts.outcomeText(result.outcome, mode: result.plan.mode),
                              ok: result.outcome.isOk)
                if !container.checkIsSaved {
                    Text(TransportSettingsTexts.notSavedText)
                        .qaudionStyle(type.labelSmall)
                        .foregroundStyle(scheme.onSurfaceVariant)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                }
                HStack(spacing: 8) {
                    secondaryButton(title: TransportSettingsTexts.confirmTitle) {
                        container.diagnostics.confirmCheck()
                    }
                    secondaryButton(title: TransportSettingsTexts.reportTitle) {
                        container.diagnostics.copyReport()
                    }
                }
                if container.diagnostics.reportCopied {
                    Text(TransportSettingsTexts.reportCopiedText)
                        .qaudionStyle(type.labelSmall)
                        .foregroundStyle(scheme.onSurfaceVariant)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                }
            }
        }
        if let confirmation = container.diagnostics.confirmation {
            Text(confirmationText(confirmation))
                .qaudionStyle(type.labelSmall)
                .foregroundStyle(scheme.onSurfaceVariant)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
        }
    }

    private func confirmationText(_ confirmation: TransportCheckConfirmation) -> String {
        let when = confirmation.date.formatted(
            Date.FormatStyle(date: .abbreviated, time: .shortened)
                .locale(Locale(identifier: AppLanguageManager.effectiveLanguageCode)))
        return TransportSettingsTexts.confirmedText(modeName: confirmation.mode.localizedLabel,
                                                    outcomeIsOk: confirmation.outcome.isOk,
                                                    dateText: when)
    }

    private func millisecondsText(_ ms: Int) -> String {
        if ms > 0 { return "\(ms) ms" }
        return "—"
    }

    /// A label above a value that may be a whole sentence (the route, the candidate counts).
    private func stackedRow(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .qaudionStyle(type.bodyMedium)
                .foregroundStyle(scheme.onSurface)
            Text(value)
                .qaudionStyle(type.labelSmall)
                .foregroundStyle(scheme.onSurfaceVariant)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(scheme.surfaceVariant.opacity(0.4))
        )
    }

    private func outcomeBanner(_ text: String, ok: Bool) -> some View {
        let tone: Color = ok ? extras.success : extras.riskHigh
        let icon: String = ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tone)
                .padding(.top, 1)
            Text(text)
                .qaudionStyle(type.labelSmall)
                .foregroundStyle(tone)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(tone.opacity(0.12))
        )
    }

    private func secondaryButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .qaudionStyle(type.labelLarge)
                .foregroundStyle(scheme.onSurface)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(scheme.surfaceVariant.opacity(0.4))
                )
        }
        .buttonStyle(.plain)
    }
}

private struct MonoIfNeededT: ViewModifier {
    let mono: Bool
    func body(content: Content) -> some View {
        if mono {
            content.font(.system(.caption, design: .monospaced))
        } else {
            content
        }
    }
}
