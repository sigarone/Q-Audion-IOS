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
    /// Entitlements Task 5 — read directly from the environment for
    /// reactivity; see `QAudionApp.swift`'s injection site doc. Gated
    /// centrally HERE rather than at each of this chip's 6 real call sites
    /// (HomeView, CallHistoryView, ChatListScreen, ContactsScreen,
    /// SettingsScreen, plus the chip's own preview) — one fix covers all
    /// of them and none can drift out of sync.
    @EnvironmentObject private var capabilityGate: CapabilityGate
    @EnvironmentObject private var appState: AppState
    /// Entitlements Task 5 — drives `.sheet(isPresented:)` for `UpgradeSheet`.
    @State private var showUpgradeSheet = false

    /// The user's current session access token.
    let accessToken: String

    @State private var busy = false

    // Manual exit selection. '' = Auto (NodePicker best). Persisted in UserDefaults,
    // mirroring Desktop `vpnPreferredNodeId` and Android's node picker.
    //
    // W-CHATDEADLOCK (2026-08-19) — was `@AppStorage`. This chip is placed
    // on 6 screens (see doc above), several of which (ChatListScreen,
    // HomeView) stay instantiated as navigation ancestors underneath an
    // active call, same as ChatDetailScreen's own `@AppStorage` removed in
    // the same pass (see that file's W-CHATDEADLOCK note for the full
    // mechanism — SwiftUI's own UserDefaults-change observer racing an
    // in-progress ForEach/Observation update on the AttributeGraph lock,
    // device-log-confirmed SIGKILL). `preferredNodeId` is read reactively
    // only inside `pickerSheet`, which dismisses itself immediately on
    // selection, so a plain `@State` synced from UserDefaults when the
    // picker opens is enough; `chooseNode(in:)` (also called from the
    // connect path, which can run without the picker ever having been
    // opened this session) reads UserDefaults directly so it never sees a
    // stale un-synced default.
    @State private var preferredNodeId: String = ""

    private static let preferredNodeIdKey = "vpn.preferredNodeId"

    private static func loadPreferredNodeId() -> String {
        UserDefaults.standard.string(forKey: preferredNodeIdKey) ?? ""
    }

    private func setPreferredNodeId(_ value: String) {
        preferredNodeId = value
        UserDefaults.standard.set(value, forKey: Self.preferredNodeIdKey)
    }
    @State private var nodes: [VpnNode] = []
    @State private var showPicker = false
    @State private var pickerLoading = false

    // MARK: - Body

    private var vpnUnlocked: Bool { capabilityGate.isUnlocked(.vpn) }

    var body: some View {
        Button(action: handleTap) {
            // Entitlements Task 5 — Capability.vpn. This Button already
            // owns its own tap (handleTap branches on vpnUnlocked itself,
            // and a long-press separately opens the exit picker) — the
            // SAME "content already has its own click" shape
            // `GatedVisualBadge`'s own doc describes, and the exact call
            // site (`VpnToggle`) its Android counterpart's kdoc names as
            // the canonical example. Visual-only: dim + lock badge, no
            // second tap target.
            GatedVisualBadge(unlocked: vpnUnlocked) {
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
        }
        .buttonStyle(.plain)
        .disabled(busy || vpnService.state.isConnecting)
        .animation(.easeInOut(duration: 0.2), value: vpnService.state)
        // Long-press the chip to choose the exit. highPriorityGesture (not
        // simultaneous) so a long-press opens the picker WITHOUT also firing the
        // button's tap action (connect/disconnect); a short tap still falls through.
        // Entitlements Task 5 — deliberately NOT gated: selecting a node here
        // only writes `preferredNodeId` (a stored preference for the NEXT
        // successful connect), it never itself calls `vpnService.connect`.
        // The one path that actually establishes a tunnel is `handleTap`,
        // which IS gated above.
        .highPriorityGesture(
            LongPressGesture(minimumDuration: 0.45).onEnded { _ in openPicker() }
        )
        .sheet(isPresented: $showPicker) { pickerSheet }
        .sheet(isPresented: $showUpgradeSheet) {
            UpgradeSheet(capability: .vpn)
                .environmentObject(appState)
        }
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
        // Entitlements Task 5 — Capability.vpn. Disconnecting an ALREADY
        // -connected tunnel is never blocked, checked BEFORE the vpnUnlocked
        // guard below on purpose: `isUnlocked` re-evaluates the claim's
        // wall-clock `exp` on every access, so an ordinary token can lapse
        // while the tunnel is still up. This chip is the only UI path that
        // calls `vpnService.disconnect()` — if the lock guard ran first, a
        // lapsed-grant user with an active tunnel would see only the
        // upgrade sheet on tap, with no way to tear it down. A mid-session
        // downgrade is handled by the stopAtBoundary revocation policy
        // server/AppState-side, not by this UI-only gate refusing the
        // disconnect action itself.
        if case .connected = vpnService.state {
            vpnService.disconnect()
            return
        }

        // Starting a NEW connection still requires the capability — only
        // the disconnect path above bypasses the lock.
        guard vpnUnlocked else {
            showUpgradeSheet = true
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
        preferredNodeId = Self.loadPreferredNodeId()
        showPicker = true
        guard nodes.isEmpty else { return }
        pickerLoading = true
        Task {
            defer { pickerLoading = false }
            nodes = (try? await vpnService.fetchNodes(accessToken: accessToken)) ?? []
        }
    }

    /// The preferred node when it's still in the live list; nil → caller uses auto-best.
    /// Reads UserDefaults directly (not the `@State` mirror) — called from
    /// the connect path too, which can run without the picker ever having
    /// been opened this session.
    private func chooseNode(in list: [VpnNode]) -> VpnNode? {
        let id = Self.loadPreferredNodeId()
        guard !id.isEmpty else { return nil }
        return list.first { $0.id == id }
    }

    @ViewBuilder
    private var pickerSheet: some View {
        NavigationStack {
            List {
                Button {
                    setPreferredNodeId("")
                    showPicker = false
                } label: {
                    pickerRow(title: "Auto", subtitle: "Best node · latency + load", selected: preferredNodeId.isEmpty)
                }
                ForEach(nodes) { n in
                    Button {
                        setPreferredNodeId(n.id)
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
    // Entitlements Task 5 — this chip now reads `@EnvironmentObject var
    // capabilityGate: CapabilityGate`, so the preview needs one injected
    // or SwiftUI fatal-errors at render time.
    VpnToggleChip(
        vpnService: VpnService(),
        accessToken: "preview-token"
    )
    .padding()
    .environmentObject(AppState())
    .environmentObject(CapabilityGate.previewInstance())
}
