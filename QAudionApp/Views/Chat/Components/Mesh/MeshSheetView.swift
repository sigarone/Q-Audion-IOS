import SwiftUI

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

    private var antennaSubtitle: String {
        switch runtime.radioState {
        case .idle: return "Spenta"
        case .error: return "Bluetooth non disponibile"
        case .scanningOnly: return "Scansione in corso…"
        default: return "Attiva · \(runtime.peers.count) dispositivi raggiungibili"
        }
    }

    private var antennaRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .foregroundStyle(runtime.antennaOn ? scheme.primary : scheme.onSurfaceVariant)
            VStack(alignment: .leading, spacing: 2) {
                Text("Antenna").qaudionStyle(type.bodyMedium).foregroundStyle(scheme.onSurface)
                Text(antennaSubtitle).qaudionStyle(type.labelSmall).foregroundStyle(scheme.onSurfaceVariant)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { runtime.antennaOn },
                set: { handleAntennaToggle($0) }
            ))
            .labelsHidden()
        }
        .padding(12)
        .background(scheme.surfaceVariant, in: RoundedRectangle(cornerRadius: 14))
    }

    private func handleAntennaToggle(_ wantOn: Bool) {
        guard MeshFeature.enabled else {
            onToast("La mesh Bluetooth non è disponibile al momento.")
            return
        }
        runtime.setAntenna(on: wantOn)
        if !wantOn {
            viewModel.selectedNodeHex = nil
        }
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
                        .foregroundStyle(isChatPeer ? extras.pqcAccent : scheme.onSurfaceVariant)
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
                    .stroke(isChatPeer ? extras.pqcAccent.opacity(0.6) : .clear, lineWidth: 1)
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
        onToast("Invio via mesh attivato — \(displayName)")
        dismiss()
    }

    @ViewBuilder
    private func relaySection(for peer: MeshRuntimePeer) -> some View {
        Button { viewModel.relaysExpanded.toggle() } label: {
            HStack {
                Text("Raggiungibili tramite \(viewModel.label(forNodeHex: peer.nodeHex).name.split(separator: " ").first.map(String.init) ?? "")")
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
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 13))
                .foregroundStyle(extras.pqcAccent)
            Text("Invio via mesh Bluetooth — \(peerName)")
                .qaudionStyle(type.labelMedium)
                .foregroundStyle(extras.pqcAccent)
            Spacer(minLength: 4)
            Button(action: onClear) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(extras.pqcAccent)
            }
            .accessibilityLabel("Torna al trasporto normale")
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(extras.pqcAccent.opacity(0.16), in: Capsule())
        .overlay(Capsule().stroke(extras.pqcAccent.opacity(0.45), lineWidth: 1))
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }
}
