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
                // Fetch node list; fall back to hardcoded Frankfurt on error.
                let api = VpnApiService()
                let nodes: [VpnNode]
                do {
                    nodes = try await api.getNodes(accessToken: accessToken)
                } catch {
                    nodes = [.frankfurtFallback]
                }
                guard let node = nodes.first else { return }
                await vpnService.connect(to: node, accessToken: accessToken)
            }
        }
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
