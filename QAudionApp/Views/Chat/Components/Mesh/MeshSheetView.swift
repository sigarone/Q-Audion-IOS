import SwiftUI
import QAudionEngine
#if canImport(UIKit)
import UIKit
#endif

/// In-chat BLE-mesh sheet: antenna on/off toggle, the proximity radar, the
/// reachable-peer list, and a selected-peer detail card offering "transmit
/// over mesh" plus its known 2-hop relay targets. 1:1 UX port of the
/// Android sibling's `MeshBottomSheet.kt` — antenna toggle, radar, peer
/// list, detail card, transport chip — redrawn with SwiftUI idioms (no
/// runtime-permission launcher needed here: unlike Android's scan/advertise
/// permission array, iOS surfaces the Bluetooth authorization prompt
/// automatically the first time `CBCentralManager`/`CBPeripheralManager` is
/// created, so there is nothing for this view to request up front).
///
/// Two behaviors mirrored exactly from the Android sibling's `MeshViewModel`:
///  1. The radar auto-highlights whichever peer corresponds to the CURRENT
///     chat's contact (`viewModel.currentChatPeerNodeHex`).
///  2. Tapping a DIFFERENT, already-known contact's device navigates
///     straight to that contact's own chat instead of selecting it here —
///     `onOpenConversation` is only invoked in that case.
struct MeshSheetView: View {
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType) private var type
    @Environment(\.dismiss) private var dismiss

    @ObservedObject var runtime: MeshRuntime
    @StateObject private var viewModel: MeshSheetViewModel
    @StateObject private var btProbe = MeshBluetoothCapabilityProbe()
    @State private var routingPreference: MeshRoutingPreference = .default
    /// The user's one-time answer about relaying other people's messages. Until it is "accepted" every antenna chip
    /// opens the consent screen instead of starting the radio, and no Bluetooth permission is asked for.
    @ObservedObject private var consent = MeshConsent.shared
    /// Whether a call is busy (mirrored by the root): the consent screen is never presented over one.
    @ObservedObject private var arbiter = MeshConsentArbiter.shared
    @State private var showingConsent: Bool = false
    /// The mode the user tapped before the consent screen came up; it is started if they accept.
    @State private var pendingConsentMode: MeshAntennaMode?

    let onToast: (String) -> Void
    let onOpenConversation: (String) -> Void

    init(
        runtime: MeshRuntime,
        conversationId: String,
        chatPeerUserId: String?,
        onToast: @escaping (String) -> Void,
        onOpenConversation: @escaping (String) -> Void
    ) {
        self.runtime = runtime
        self._viewModel = StateObject(wrappedValue: MeshSheetViewModel(
            conversationId: conversationId, chatPeerUserId: chatPeerUserId
        ))
        self.onToast = onToast
        self.onOpenConversation = onOpenConversation
    }

    private var selectedPeer: MeshRuntimePeer? {
        runtime.peers.first(where: { $0.nodeHex == viewModel.selectedNodeHex })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                antennaRow
                    .padding(.top, 8)
                routingRow
                    .padding(.top, 10)
                radarSection
                    .padding(.top, 12)
                peerListSection
                    .padding(.top, 12)
                if let peer = selectedPeer {
                    detailCard(for: peer)
                        .padding(.top, 12)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(scheme.background)
        .presentationDetents([.medium, .large])
        // R2 — select this chat's own contact as soon as their device is on
        // the radar. Both hooks are needed: onAppear covers the sheet opening
        // while the peer is already discovered, onChange covers it arriving a
        // moment later, which is the common case since discovery takes a scan
        // cycle. The view model's own guards make repeat calls harmless.
        .onAppear {
            viewModel.autoSelectChatPeer(visibleNodeHexes: runtime.peers.map { $0.nodeHex })
            if let peer = viewModel.chatPeerUserId {
                routingPreference = MeshRoutingPreferenceStore().preference(for: peer)
            }
            // W-MESHDEAD — independent of MeshFeature.enabled on purpose,
            // see MeshBluetoothCapabilityProbe's kdoc. It builds a
            // CBCentralManager, which asks for the Bluetooth permission, so
            // it waits for the consent: no Bluetooth before the user said yes.
            if consentAnswered { btProbe.start() }
        }
        // Single-parameter onChange on purpose: every other call site in this
        // app uses it, and the two-parameter form is iOS 17+.
        .onChange(of: runtime.peers.map { $0.nodeHex }) { hexes in
            viewModel.autoSelectChatPeer(visibleNodeHexes: hexes)
        }
        .onChange(of: consent.state) { state in
            if state != .undecided { btProbe.start() }
        }
        .meshConsentSheet(
            wanted: $showingConsent,
            callBusy: arbiter.callBusy,
            onAccept: acceptConsent,
            onDecline: declineConsent
        )
    }

    /// The consent screen was answered (either way): the Bluetooth may be probed and a mode may be started, within
    /// what the answer allows (`MeshModePolicy`).
    private var consentAnswered: Bool {
        consent.state != .undecided
    }

    /// "Attiva" on the consent screen: starts the mode the user had tapped.
    private func acceptConsent() {
        let mode: MeshAntennaMode = pendingConsentMode ?? .fullMesh
        pendingConsentMode = nil
        showingConsent = false
        runtime.acceptConsentAndStart(mode: mode)
    }

    /// "Solo i miei messaggi": relaying stays off and the antenna comes up in direct mode (or in the visible-only mode
    /// the user had tapped); nothing is forwarded for anyone else.
    private func declineConsent() {
        let tapped: MeshAntennaMode? = pendingConsentMode
        pendingConsentMode = nil
        showingConsent = false
        runtime.declineRelayAndUseDirect(startIfOff: true, preferred: tapped)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .foregroundStyle(scheme.primary)
            Text("Mesh Bluetooth")
                .qaudionStyle(type.titleSmall)
                .foregroundStyle(scheme.onSurface)
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .foregroundStyle(scheme.onSurfaceVariant)
            }
            .accessibilityLabel("Chiudi")
        }
        .padding(.top, 12)
    }

    // MARK: - Antenna

    /// Label of the "off" antenna mode, shared by the chip and the subtitle.
    private var antennaOffLabel: String {
        String(localized: "mesh_sheet.antenna_off", defaultValue: "Spenta", comment: "Bluetooth mesh sheet: antenna mode off (chip label and subtitle of the antenna row).")
    }

    /// Subtitle when the kill switch has turned the mesh off for now. It is a switch for everybody, not a setting of this
    /// account, so the text does not say "for this account".
    private var featureUnavailableLabel: String {
        String(localized: "mesh_sheet.feature_unavailable", defaultValue: "Mesh temporaneamente non disponibile", comment: "Bluetooth mesh sheet, antenna row subtitle when the mesh has been switched off for everyone for now (remote kill switch). Not a per-account state.")
    }

    private var antennaSubtitle: String {
        // Before the consent the Bluetooth is not even probed, so the only
        // truth is "off"; the chips below open the consent screen.
        guard consentAnswered else { return antennaOffLabel }
        switch btProbe.status {
        case .checking:
            return "Verifica del Bluetooth in corso…"
        case .unsupported:
            return "Bluetooth non supportato su questo dispositivo"
        case .authorizationDenied:
            return "Permesso Bluetooth negato — tocca per aprire Impostazioni"
        case .poweredOff:
            // Says where the switch really is. The button below opens this
            // app's page in Settings (see `openSettingsLabel`), which has no
            // Bluetooth on/off switch, so the old "tocca per aprire
            // Impostazioni" promised something the tap did not deliver.
            return String(
                localized: "mesh_sheet.bluetooth_off_hint",
                defaultValue: "Bluetooth spento — accendilo dal Centro di Controllo o da Impostazioni > Bluetooth",
                comment: "Bluetooth mesh sheet, antenna row subtitle when the phone's Bluetooth radio is switched off: tells the user where to turn it on."
            )
        case .ready:
            switch runtime.antennaMode {
            case nil:
                if case .error = runtime.radioState { return "Bluetooth non disponibile" }
                // W-MESHDEAD — distinguishes "radio is fine, you just haven't
                // turned it on" from "the mesh has been switched off for
                // everyone for now" (the remote kill switch), instead of both
                // reading as the same flat "Spenta".
                return MeshFeature.enabled ? antennaOffLabel : featureUnavailableLabel
            case .visibleOnly:
                return "Visibile · raggiungibile dai vicini"
            case .direct:
                if case .scanningOnly = runtime.radioState { return "Diretta · scansione in corso…" }
                return "Diretta · \(runtime.peers.count) dispositivi raggiungibili"
            case .fullMesh:
                if case .scanningOnly = runtime.radioState { return "Mesh completa · scansione in corso…" }
                return "Mesh completa · \(runtime.peers.count) dispositivi raggiungibili"
            }
        }
    }

    /// Whether this row has an unmet BLUETOOTH-LEVEL blocker (denied
    /// permission or the system radio off) — distinct from the antenna
    /// simply being off by choice, or the server flag not being on yet.
    /// Drives whether the row shows the three antenna chips or a single
    /// "Apri Impostazioni" action.
    private var hasBluetoothBlocker: Bool {
        btProbe.status == .authorizationDenied || btProbe.status == .poweredOff
    }

    private var antennaIconTint: Color {
        if hasBluetoothBlocker || btProbe.status == .unsupported { return extras.warning }
        return runtime.antennaMode != nil ? scheme.primary : scheme.onSurfaceVariant
    }

    /// Four explicit intents rather than an on/off toggle-of-a-toggle: off,
    /// `.visibleOnly` (reachable — advertise + accept incoming connections,
    /// no scan/connect-out, no relay for others; lowest power), `.direct`
    /// (advertise + scan + connect out, own messages only, no relay: what a
    /// user who did not allow relaying gets by default), and `.fullMesh` (the
    /// original behaviour, which also relays). Port of the Android sibling's
    /// `AntennaRow` plus the direct mode.
    ///
    /// W-MESHDEAD (2026-08-15) — reported live: tapping "Visibile"/"Mesh
    /// completa" never selected them, the row always read "Spenta", and
    /// there was nothing to tap that explained why or fixed it. Root cause:
    /// this row's three chips were the ONLY thing gating whether
    /// CoreBluetooth ever got asked its real state at all (`BleMeshTransport`
    /// only constructs its `CBCentralManager`/`CBPeripheralManager` inside
    /// `start()`, downstream of the `MeshFeature.enabled` guard in
    /// `handleAntennaSelect`) — so a denied permission or a powered-off
    /// radio looked IDENTICAL to a server flag that simply wasn't on yet.
    /// [btProbe] now reads the real Bluetooth state unconditionally (see its
    /// kdoc), and this row shows a genuine fix — Settings — for the two
    /// cases that have one, instead of three dead chips.
    private var antennaRow: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .foregroundStyle(antennaIconTint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Antenna").qaudionStyle(type.bodyMedium).foregroundStyle(scheme.onSurface)
                    Text(antennaSubtitle).qaudionStyle(type.labelSmall).foregroundStyle(scheme.onSurfaceVariant)
                }
                Spacer()
            }
            if hasBluetoothBlocker {
                openBluetoothSettingsButton
            } else if btProbe.status == .unsupported {
                EmptyView() // nothing tappable fixes this; the subtitle already says so
            } else {
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        antennaModeChip(label: antennaOffLabel, selected: runtime.antennaMode == nil) {
                            handleAntennaSelect(nil)
                        }
                        antennaModeChip(label: "Visibile", selected: runtime.antennaMode == .visibleOnly) {
                            handleAntennaSelect(.visibleOnly)
                        }
                    }
                    HStack(spacing: 8) {
                        antennaModeChip(label: "Diretta", selected: runtime.antennaMode == .direct) {
                            handleAntennaSelect(.direct)
                        }
                        antennaModeChip(label: "Mesh completa", selected: runtime.antennaMode == .fullMesh) {
                            handleAntennaSelect(.fullMesh)
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(scheme.surfaceVariant, in: RoundedRectangle(cornerRadius: 14))
    }

    /// Both blockers open the same page: THIS app's page in Settings, the only
    /// Settings page the public API can open. For a denied permission that is
    /// exactly where the Bluetooth switch is, so "Apri Impostazioni" is true.
    /// For a radio that is off it is not: the system Bluetooth switch lives in
    /// Control Center and Settings > Bluetooth, so the label names the page
    /// that opens instead of promising the switch (the subtitle says where the
    /// switch is).
    private var openSettingsLabel: String {
        if btProbe.status == .poweredOff {
            return String(
                localized: "mesh_sheet.open_app_settings",
                defaultValue: "Impostazioni dell'app",
                comment: "Bluetooth mesh sheet: button that opens this app's page in the Settings app (shown while the phone's Bluetooth is off; it does not contain the system Bluetooth switch)."
            )
        }
        return String(localized: "Apri Impostazioni")
    }

    private var openBluetoothSettingsButton: some View {
        Button {
            #if canImport(UIKit)
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
            #endif
        } label: {
            Text(openSettingsLabel)
                .qaudionStyle(type.labelMedium)
                .foregroundStyle(scheme.onPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(scheme.primary, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private func antennaModeChip(label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .qaudionStyle(type.labelMedium)
                .foregroundStyle(selected ? scheme.onPrimary : scheme.onSurfaceVariant)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(selected ? scheme.primary : scheme.surface, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private func handleAntennaSelect(_ mode: MeshAntennaMode?) {
        // W-MESHFLAGVIS (2026-08-13) — reported live: "Visibile"/"Mesh
        // completa" never become selectable. The server-side flag
        // (mesh_ble.enabled) is confirmed `true` globally with no negative
        // per-user override, but this device's LOCAL resolution of it could
        // not be proven from the existing telemetry: FeatureFlags'
        // fetch-summary log line carries the full flag-key dump, which is
        // long enough (`LOG_OTLP_EXPORT_ENABLED` alone is a 23-char run of
        // letters) to trip the shipper's redactor and vanish whole — the
        // fetch could be succeeding or silently failing and both look
        // identical off-device. Numeric-only tail so this ONE line survives
        // regardless of what the general fetch summary does.
        let flagOn: Int = MeshFeature.enabled ? 1 : 0
        RTLog.info("call", "mesh antenna_tap flag=\(flagOn)")
        guard MeshFeature.enabled else {
            onToast("La mesh Bluetooth non è disponibile al momento.")
            return
        }
        // Turning the radio ON needs the consent screen to have been answered
        // first, and full mesh (which relays other people's messages through
        // this phone) needs a yes to relaying: ask, and start in the tapped
        // mode only if they accept. Turning it OFF never needs asking.
        if let mode, !MeshModePolicy.mayStart(featureEnabled: true, consent: consent.state, mode: mode) {
            pendingConsentMode = mode
            showingConsent = true
            return
        }
        runtime.setAntenna(mode: mode)
        // "Spenta" is a decision, not a session state: it has to survive the
        // next launch or the auto-start would undo it. Turning it back on by
        // hand re-arms auto-start, because the user just said they want to be
        // reachable and should not have to say it again tomorrow.
        runtime.setAutoStart(mode != nil)
        if mode == nil {
            viewModel.selectedNodeHex = nil
        }
    }

    // MARK: - Network for this contact

    /// Which network this contact's messages take, remembered per contact.
    ///
    /// Separate from the antenna row above even though both are three chips,
    /// because they answer different questions: the antenna is this device's
    /// radio right now, this is one conversation and it outlives the sheet.
    /// Mixing them would make turning the radio off look like it changed a
    /// preference. 1:1 with Android's `RoutingPreferenceRow`.
    @ViewBuilder
    private var routingRow: some View {
        if let peer = viewModel.chatPeerUserId {
            let reach: (reachable: Bool, viaBridgeNodeHex: String?) = {
                guard let hex = viewModel.currentChatPeerNodeHex else { return (false, nil) }
                return runtime.reach(toNodeHex: hex)
            }()
            let bridgeName: String? = reach.viaBridgeNodeHex.map { viewModel.label(forNodeHex: $0).name }
            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.left.arrow.right")
                        .foregroundStyle(extras.bluetoothAccent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Rete per questo contatto")
                            .qaudionStyle(type.bodyMedium).foregroundStyle(scheme.onSurface)
                        Text(routingSubtitle(reachable: reach.reachable, bridgeName: bridgeName))
                            .qaudionStyle(type.labelSmall).foregroundStyle(scheme.onSurfaceVariant)
                    }
                    Spacer()
                }
                HStack(spacing: 8) {
                    antennaModeChip(label: "Preferisci BT", selected: routingPreference == .preferMesh) {
                        setRouting(.preferMesh, for: peer)
                    }
                    antennaModeChip(label: "Solo rete", selected: routingPreference == .networkOnly) {
                        setRouting(.networkOnly, for: peer)
                    }
                    antennaModeChip(label: "Solo BT", selected: routingPreference == .meshOnly) {
                        setRouting(.meshOnly, for: peer)
                    }
                }
            }
            .padding(12)
            .background(scheme.surfaceVariant, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    /// `bridgeName` is non-nil only when the contact is reachable through a
    /// device in range rather than directly — the case this used to read as
    /// flatly unreachable, since the old boolean never consulted
    /// `relayNodeHexes` at all.
    private func routingSubtitle(reachable: Bool, bridgeName: String?) -> String {
        switch routingPreference {
        case .preferMesh:
            if let bridgeName {
                return "Bluetooth quando il contatto è vicino · ora raggiungibile tramite \(bridgeName)"
            }
            return reachable
                ? "Bluetooth quando il contatto è vicino · ora è raggiungibile"
                : "Bluetooth quando il contatto è vicino · ora passa dalla rete"
        case .networkOnly:
            return "Sempre dalla rete pubblica"
        case .meshOnly:
            if let bridgeName {
                return "Solo Bluetooth · raggiungibile tramite \(bridgeName)"
            }
            return reachable
                ? "Solo Bluetooth · il contatto è raggiungibile"
                : "Solo Bluetooth · in attesa che il contatto sia vicino"
        }
    }

    private func setRouting(_ preference: MeshRoutingPreference, for peer: String) {
        MeshRoutingPreferenceStore().setPreference(preference, for: peer)
        routingPreference = preference
    }

    // MARK: - Radar

    private var radarSection: some View {
        VStack(spacing: 6) {
            MeshRadarView(
                peers: runtime.peers,
                selectedNodeHex: viewModel.selectedNodeHex,
                expandedNodeHex: viewModel.relaysExpanded ? viewModel.selectedNodeHex : nil,
                currentChatPeerNodeHex: viewModel.currentChatPeerNodeHex,
                isKnown: { viewModel.resolveContact(nodeHex: $0) != nil }
            )
            .frame(width: 240, height: 240)
            Text("La distanza dal centro è l'intensità del segnale (vicinanza), non una direzione: il Bluetooth non dà una bussola.")
                .qaudionStyle(type.labelSmall)
                .foregroundStyle(scheme.onSurfaceVariant)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Peer list

    @ViewBuilder
    private var peerListSection: some View {
        if !runtime.antennaOn {
            hintText("Accendi l'antenna per cercare dispositivi Q-Audion nel raggio del Bluetooth.")
        } else if runtime.antennaMode == .visibleOnly {
            hintText("Sei visibile — chi ti cerca può raggiungerti, ma solo finché l'app è aperta. Passa a \"Diretta\" o \"Mesh completa\" per vedere anche tu i dispositivi vicini e restare raggiungibile in secondo piano.")
        } else if runtime.peers.isEmpty {
            hintText("Nessun dispositivo raggiungibile al momento.")
        } else {
            VStack(spacing: 6) {
                ForEach(runtime.peers) { peer in
                    peerRow(peer)
                }
            }
        }
    }

    private func hintText(_ text: String) -> some View {
        Text(text)
            .qaudionStyle(type.bodySmall)
            .foregroundStyle(scheme.onSurfaceVariant)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 12)
    }

    private func peerRow(_ peer: MeshRuntimePeer) -> some View {
        let label = viewModel.label(forNodeHex: peer.nodeHex)
        let isChatPeer = peer.nodeHex == viewModel.currentChatPeerNodeHex
        return Button { handlePeerTap(peer) } label: {
            HStack(spacing: 10) {
                Circle()
                    .fill(label.known ? scheme.secondary : extras.trustUnverified)
                    .frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 1) {
                    Text(label.name).qaudionStyle(type.bodyMedium).foregroundStyle(scheme.onSurface)
                    Text(isChatPeer ? "Il contatto di questa chat" : (label.known ? "Contatto noto" : "Non verificato"))
                        .qaudionStyle(type.labelSmall)
                        .foregroundStyle(isChatPeer ? extras.bluetoothAccent : scheme.onSurfaceVariant)
                }
                Spacer()
                if !peer.relayNodeHexes.isEmpty {
                    relayCountChip(peer.relayNodeHexes.count)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                viewModel.selectedNodeHex == peer.nodeHex ? scheme.primary.opacity(0.12) : scheme.surfaceVariant,
                in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isChatPeer ? extras.bluetoothAccent.opacity(0.6) : .clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    /// Tapping a peer that resolves to a DIFFERENT known contact than this
    /// chat's own jumps straight to that contact's chat — mirrors Android's
    /// `MeshViewModel.onPeerTapped`. Otherwise (this chat's own contact, or
    /// an unresolved device) falls back to the in-sheet selection flow.
    private func handlePeerTap(_ peer: MeshRuntimePeer) {
        if peer.nodeHex != viewModel.currentChatPeerNodeHex,
           let contact = viewModel.resolveContact(nodeHex: peer.nodeHex) {
            dismiss()
            onOpenConversation(contact.userId)
            return
        }
        viewModel.relaysExpanded = false
        viewModel.markSelectionTouched()
        viewModel.selectedNodeHex = peer.nodeHex
    }

    private func relayCountChip(_ count: Int) -> some View {
        Text("+\(count)")
            .qaudionStyle(type.labelSmall)
            .foregroundStyle(extras.warning)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(extras.warning.opacity(0.16), in: Capsule())
    }

    // MARK: - Detail card

    private func detailCard(for peer: MeshRuntimePeer) -> some View {
        let label = viewModel.label(forNodeHex: peer.nodeHex)
        return VStack(alignment: .leading, spacing: 10) {
            Text(label.name).qaudionStyle(type.titleSmall).foregroundStyle(scheme.onSurface)
            Text("nodo · \(peer.nodeHex)")
                .qaudionStyle(type.labelSmall)
                .foregroundStyle(scheme.onSurfaceVariant)
            Text(signalLabel(for: peer))
                .qaudionStyle(type.labelMedium)
                .foregroundStyle(extras.success)

            sendButton(label: "Invia messaggio via mesh") {
                selectTarget(nodeHex: peer.nodeHex, displayName: label.name)
            }

            if !peer.relayNodeHexes.isEmpty {
                relaySection(for: peer)
            }
        }
        .padding(14)
        .background(scheme.surfaceVariant, in: RoundedRectangle(cornerRadius: 16))
    }

    private func signalLabel(for peer: MeshRuntimePeer) -> String {
        switch peer.radiusFraction {
        case ..<0.4: return "Diretta · segnale forte"
        case ..<0.7: return "Diretta · segnale medio"
        default: return "Diretta · segnale debole"
        }
    }

    private func sendButton(label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "paperplane.fill").font(.system(size: 13))
                Text(label).qaudionStyle(type.labelLarge)
            }
            .foregroundStyle(scheme.onPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(scheme.primary, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func selectTarget(nodeHex: String, displayName: String) {
        runtime.selectTarget(conversationId: viewModel.conversationId, nodeHex: nodeHex, displayName: displayName)
        // R5 — in .visibleOnly this device advertises but never scans, so it
        // cannot open a link itself; it can only answer a device that connects
        // in. Announcing "invio attivato" and nothing else is how a message
        // ended up reported as sent while the peer never received it.
        if runtime.antennaMode == .visibleOnly {
            onToast(
                "Invio via mesh attivato — \(displayName). In modalità Visibile questo telefono non avvia "
                    + "il collegamento: la consegna dipende dall'altro dispositivo. Passa a Diretta o Mesh completa per inviare subito."
            )
        } else {
            onToast("Invio via mesh attivato — \(displayName)")
        }
        dismiss()
    }

    @ViewBuilder
    private func relaySection(for peer: MeshRuntimePeer) -> some View {
        // Section header text pre-built as a plain `let` (not inline string
        // interpolation inside the ViewBuilder) — CLAUDE.md §13: keep
        // multi-segment formatting out of deeply-nested closure/builder
        // scopes.
        let viaName = viewModel.label(forNodeHex: peer.nodeHex).name
        let headerText = "Raggiungibili tramite " + viaName
        Button { viewModel.relaysExpanded.toggle() } label: {
            HStack {
                Text(headerText)
                    .qaudionStyle(type.bodySmall)
                    .foregroundStyle(scheme.onSurface)
                Spacer()
                relayCountChip(peer.relayNodeHexes.count)
                Image(systemName: "chevron.down").font(.system(size: 12)).foregroundStyle(scheme.onSurfaceVariant)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(scheme.outline, lineWidth: 1))
        }
        .buttonStyle(.plain)

        if viewModel.relaysExpanded {
            VStack(spacing: 6) {
                ForEach(peer.relayNodeHexes, id: \.self) { relayHex in
                    relayRow(relayHex)
                }
            }
        }
    }

    private func relayRow(_ relayHex: String) -> some View {
        let label = viewModel.label(forNodeHex: relayHex)
        return Button {
            handleRelayTap(relayHex: relayHex, label: label)
        } label: {
            HStack(spacing: 10) {
                Circle()
                    .fill(label.known ? scheme.secondary : extras.trustUnverified)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(label.name).qaudionStyle(type.bodySmall).foregroundStyle(scheme.onSurface)
                    Text("2 hop").qaudionStyle(type.labelSmall).foregroundStyle(scheme.onSurfaceVariant)
                }
                Spacer()
                Text(label.known ? "Invia" : "Verifica")
                    .qaudionStyle(type.labelMedium)
                    .foregroundStyle(label.known ? scheme.primary : extras.warning)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(scheme.surface, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private func handleRelayTap(relayHex: String, label: (name: String, known: Bool)) {
        if label.known {
            selectTarget(nodeHex: relayHex, displayName: label.name)
        } else {
            onToast("Verifica il contatto prima di inviare")
        }
    }
}

/// Persistent chip shown above the composer while a mesh peer is the active
/// transmit target, so the current channel is always visible. Cleared with
/// the X, returning to the normal transport. 1:1 port of the Android
/// sibling's `MeshTransportChip`.
struct MeshTransportChip: View {
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType) private var type

    let peerName: String
    /// Whether that peer is reachable RIGHT NOW — antenna on and the device in
    /// range. Distinct from "a target is armed", which survives the antenna
    /// being switched off and the peer walking away. The chip used to claim
    /// "invio via mesh" in both states, which used to be a promise the
    /// transport couldn't keep — fixed by MeshOutboxStore/MeshOutboxDrain
    /// (see IOS_BLE_MESH_DESIGN.md §6): a message sent while unreachable is
    /// now held and retried once the peer is back in range, same as the
    /// Android sibling, rather than failing on the spot.
    let reachable: Bool
    let onClear: () -> Void

    /// Unreachable is not an error — the message is held and retried when
    /// the peer reappears (MeshOutboxDrain), up to MeshOutboxStore.maxAgeMs
    /// — so it warns rather than alarms.
    private var tint: Color { reachable ? extras.bluetoothAccent : extras.trustUnverified }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 13))
                .foregroundStyle(tint)
            Text(reachable
                 ? "Invio via mesh Bluetooth — \(peerName)"
                 : "Mesh Bluetooth — \(peerName) non raggiungibile: il messaggio resta in attesa")
                .qaudionStyle(type.labelMedium)
                .foregroundStyle(tint)
            Spacer(minLength: 4)
            Button(action: onClear) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(tint)
            }
            .accessibilityLabel("Torna al trasporto normale")
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(tint.opacity(0.16), in: Capsule())
        .overlay(Capsule().stroke(tint.opacity(0.45), lineWidth: 1))
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }
}
