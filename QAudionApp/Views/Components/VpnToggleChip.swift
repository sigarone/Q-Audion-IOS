// VpnToggleChip.swift — Q-Audion iOS
//
// Compact VPN status chip for the app's top bar / toolbar.
// Mirrors Android `VpnToggle.kt` and Desktop `VpnToggle.svelte`.
//
// Placement: pass as a `.toolbar` item in HomeView or as an overlay chip.
//
// Usage:
//   VpnToggleChip(vpnService: vpnService, accessToken: token)
//
// Tapping while disconnected: fetches first available node → connects.
// Tapping while connected: disconnects.
// Disabled while a state transition is in progress.

import SwiftUI
import NetworkExtension

struct VpnToggleChip: View {
    @ObservedObject var vpnService: VpnService

    /// The user's current session access token.
    let accessToken: String

    @State private var busy = false

    // Manual exit selection. '' = Auto (NodePicker best). Persisted in UserDefaults,
    // mirroring Desktop `vpnPreferredNodeId` and Android's node picker.
    @AppStorage("vpn.preferredNodeId") private var preferredNodeId: String = ""
    @State private var nodes: [VpnNode] = []
    @State private var showPicker = false
    @State private var pickerLoading = false

    // MARK: - Body

    var body: some View {
        Button(action: handleTap) {
            HStack(spacing: 5) {
                chipIcon
                Text(vpnService.state.statusLabel)
                    .font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(chipBackground, in: Capsule())
            .overlay(Capsule().stroke(chipBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(busy || vpnService.state.isConnecting)
        .animation(.easeInOut(duration: 0.2), value: vpnService.state)
        // Long-press the chip to choose the exit. highPriorityGesture (not
        // simultaneous) so a long-press opens the picker WITHOUT also firing the
        // button's tap action (connect/disconnect); a short tap still falls through.
        .highPriorityGesture(
            LongPressGesture(minimumDuration: 0.45).onEnded { _ in openPicker() }
        )
        .sheet(isPresented: $showPicker) { pickerSheet }
    }

    // MARK: - Icon

    @ViewBuilder
    private var chipIcon: some View {
        if vpnService.state.isConnecting {
            ProgressView()
                .progressViewStyle(.circular)
                .scaleEffect(0.55)
                .frame(width: 14, height: 14)
        } else {
            Image(systemName: vpnService.state.isConnected
                  ? "lock.fill" : "lock.open")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(chipTextColor)
        }
    }

    // MARK: - Styling

    private var chipBackground: Color {
        switch vpnService.state {
        case .connected:   return Color.green.opacity(0.15)
        case .error:       return Color.red.opacity(0.12)
        default:           return Color.primary.opacity(0.06)
        }
    }

    private var chipBorder: Color {
        switch vpnService.state {
        case .connected:   return Color.green.opacity(0.4)
        case .error:       return Color.red.opacity(0.35)
        default:           return Color.primary.opacity(0.15)
        }
    }

    private var chipTextColor: Color {
        switch vpnService.state {
        case .connected:   return .green
        case .error:       return .red
        default:           return .secondary
        }
    }

    // MARK: - Action

    private func handleTap() {
        guard !busy else { return }

        if case .connected = vpnService.state {
            vpnService.disconnect()
            return
        }

        busy = true
        Task {
            defer { busy = false }
            do {
                // Fetch node list via VpnService (reuses its persistent
                // cert-pinned session — no per-tap URLSession allocation).
                let list: [VpnNode]
                do {
                    list = try await vpnService.fetchNodes(accessToken: accessToken)
                } catch {
                    list = [.frankfurtFallback]
                }
                nodes = list  // cache for the picker UI
                // Honour the manual exit choice when its node is still in the live list;
                // otherwise auto-select the best (latency + load + jurisdiction).
                let node: VpnNode
                if let preferred = chooseNode(in: list) {
                    node = preferred
                } else if let best = await VpnNodePicker.selectBest(list) {
                    node = best
                } else {
                    return
                }
                await vpnService.connect(to: node, accessToken: accessToken)
            }
        }
    }

    // MARK: - Manual exit picker

    private func openPicker() {
        showPicker = true
        guard nodes.isEmpty else { return }
        pickerLoading = true
        Task {
            defer { pickerLoading = false }
            nodes = (try? await vpnService.fetchNodes(accessToken: accessToken)) ?? []
        }
    }

    /// The preferred node when it's still in the live list; nil → caller uses auto-best.
    private func chooseNode(in list: [VpnNode]) -> VpnNode? {
        guard !preferredNodeId.isEmpty else { return nil }
        return list.first { $0.id == preferredNodeId }
    }

    @ViewBuilder
    private var pickerSheet: some View {
        NavigationStack {
            List {
                Button {
                    preferredNodeId = ""
                    showPicker = false
                } label: {
                    pickerRow(title: "Auto", subtitle: "Best node · latency + load", selected: preferredNodeId.isEmpty)
                }
                ForEach(nodes) { n in
                    Button {
                        preferredNodeId = n.id
                        showPicker = false
                    } label: {
                        pickerRow(
                            title: n.city.isEmpty ? n.id : n.city,
                            subtitle: "\(n.country) · \(Int((n.loadPct * 100).rounded()))% load",
                            selected: preferredNodeId == n.id
                        )
                    }
                }
                if pickerLoading && nodes.isEmpty {
                    Text("Loading locations…").foregroundStyle(.secondary)
                }
            }
            .navigationTitle("VPN exit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showPicker = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private func pickerRow(title: String, subtitle: String, selected: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(.primary)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if selected {
                Image(systemName: "checkmark").foregroundStyle(.green)
            }
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Fallback node

private extension VpnNode {
    /// Hardcoded fallback when /vpn/nodes is unreachable.
    static let frankfurtFallback = VpnNode(
        id: "de-1",
        country: "DE",
        city: "Frankfurt",
        lat: 50.1109,
        lon: 8.6821,
        quicAddr: "217.160.65.35:51820",
        wsAddr: "",
        loadPct: 0,
        pingMs: 999
    )
}

// MARK: - Preview

#Preview {
    VpnToggleChip(
        vpnService: VpnService(),
        accessToken: "preview-token"
    )
    .padding()
}
