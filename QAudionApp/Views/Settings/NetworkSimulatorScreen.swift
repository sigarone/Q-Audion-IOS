import SwiftUI
import QAudionEngine

/// Dev-only profile for the in-call `NetworkConditionSimulator`. 1:1 with
/// Android `NetworkConditionSimulator.Profile` — same six presets, same
/// Italian labels, same `(outboundDelayMs, outboundLossRatio,
/// inboundLossRatio, offline)` tuple. Engine wiring pending: today this is
/// a UI-only stub (the iOS `CallController` still flies the production
/// fast path). When the engine surfaces a per-call simulator hook,
/// `NetworkSimulatorContainer.select(_:)` will plumb to it.
public struct NetSimProfile: Identifiable, Equatable {
    public let id: String
    public let label: String
    public let outboundDelayMs: Int
    public let outboundLossRatio: Double
    public let inboundLossRatio: Double
    public let offline: Bool

    public init(id: String, label: String,
                outboundDelayMs: Int,
                outboundLossRatio: Double,
                inboundLossRatio: Double,
                offline: Bool = false) {
        self.id = id; self.label = label
        self.outboundDelayMs = outboundDelayMs
        self.outboundLossRatio = outboundLossRatio
        self.inboundLossRatio = inboundLossRatio
        self.offline = offline
    }

    /// "Effetto" descriptor used for the row subtitle. Matches Android's
    /// `buildString {}` block in `ProfileRow`.
    public var descriptor: String {
        var parts: [String] = []
        if outboundDelayMs > 0 { parts.append("+\(outboundDelayMs)ms") }
        if outboundLossRatio > 0 {
            parts.append(String(format: "tx-loss %.0f%%", outboundLossRatio * 100.0))
        }
        if inboundLossRatio > 0 && inboundLossRatio != outboundLossRatio {
            parts.append(String(format: "rx-loss %.0f%%", inboundLossRatio * 100.0))
        }
        if offline { parts.append("offline") }
        if parts.isEmpty { return "fast-path (no overhead)" }
        return parts.joined(separator: " ")
    }
}

extension NetSimProfile {
    /// Canonical preset list — same order, same values, same labels as
    /// Android `NetworkConditionSimulator.availableProfiles`.
    public static let presets: [NetSimProfile] = [
        .init(id: "off",         label: "Normale (rete reale)",
              outboundDelayMs: 0,   outboundLossRatio: 0.0, inboundLossRatio: 0.0),
        .init(id: "highLatency", label: "Alta latenza (300 ms)",
              outboundDelayMs: 300, outboundLossRatio: 0.0, inboundLossRatio: 0.0),
        .init(id: "lossy",       label: "Perdita pacchetti 5%",
              outboundDelayMs: 0,   outboundLossRatio: 0.05, inboundLossRatio: 0.05),
        .init(id: "veryLossy",   label: "Perdita pacchetti 20%",
              outboundDelayMs: 0,   outboundLossRatio: 0.20, inboundLossRatio: 0.20),
        .init(id: "satellite",   label: "Satellite (700 ms + 2%)",
              outboundDelayMs: 700, outboundLossRatio: 0.02, inboundLossRatio: 0.02),
        .init(id: "offline",     label: "Offline (tutti i pacchetti scartati)",
              outboundDelayMs: 0,   outboundLossRatio: 1.0, inboundLossRatio: 1.0,
              offline: true),
    ]
}

/// Container for the dev simulator screen. UI-only stub today; when the
/// engine wires `NetworkConditionSimulator` on iOS, `select(_:)` will
/// dispatch the choice to the engine via a future `appState.setNetSim(_:)`.
@MainActor
final class NetworkSimulatorContainer: ObservableObject {
    @Published var active: NetSimProfile = NetSimProfile.presets.first!

    let availableProfiles: [NetSimProfile] = NetSimProfile.presets

    func select(_ p: NetSimProfile) {
        // W69: ora wired al `NetworkConditionSimulator` engine-side.
        // Il setProfile è effetto immediato sul prossimo frame del
        // CallService loop (TX e RX hooks).
        active = p
        let enginePf = NetworkConditionSimulator.Profile(
            id: p.id,
            label: p.label,
            outboundDelayMs: p.outboundDelayMs,
            outboundLossRatio: p.outboundLossRatio,
            inboundLossRatio: p.inboundLossRatio,
            offline: p.offline
        )
        NetworkConditionSimulator.shared.setProfile(enginePf)
    }
}

/// "Simulatore rete (dev)" — 1:1 visual port of Android
/// `NetworkSimulatorRoute` in
/// `feature-call/.../devtools/NetworkSimulatorScreen.kt`.
struct NetworkSimulatorScreen: View {
    @StateObject private var container = NetworkSimulatorContainer()
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType) private var type

    var body: some View {
        ZStack {
            scheme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    introText
                        .padding(.bottom, 16)
                    profilesList
                    Spacer().frame(height: 24)
                    effectLabel
                    statusBox
                        .padding(.top, 4)
                    Spacer().frame(height: 32)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
        }
        .navigationTitle("Simulatore rete (dev)")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Intro

    private var introText: some View {
        // Verbatim from Android: NetworkSimulatorRoute Text(...).
        Text("Inietta latenza / perdita pacchetti / offline nelle chiamate attive. Il profilo \"Normale\" ripristina il comportamento di produzione.")
            .qaudionStyle(type.bodySmall)
            .foregroundStyle(scheme.onSurfaceVariant)
    }

    // MARK: - Profile rows

    private var profilesList: some View {
        VStack(spacing: 8) {
            ForEach(container.availableProfiles) { profile in
                profileRow(profile)
            }
        }
    }

    private func profileRow(_ profile: NetSimProfile) -> some View {
        let isSelected = container.active.id == profile.id
        return Button {
            container.select(profile)
        } label: {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: isSelected
                      ? "checkmark.circle"
                      : "circle")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(isSelected ? scheme.primary
                                                : scheme.onSurfaceVariant)
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.label)
                        .qaudionStyle(type.bodyLarge)
                        .fontWeight(.semibold)
                        .foregroundStyle(isSelected ? scheme.primary
                                                    : scheme.onSurface)
                    Text(profile.descriptor)
                        .font(.system(size: 11, weight: .regular,
                                      design: .monospaced))
                        .tracking(0.5)
                        .foregroundStyle(scheme.onSurfaceVariant)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(scheme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? scheme.primary
                                       : scheme.outline.opacity(0.5),
                            lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Effect status

    private var effectLabel: some View {
        Text("Effetto corrente:")
            .qaudionStyle(type.labelMedium)
            .fontWeight(.semibold)
            .foregroundStyle(scheme.onSurface)
    }

    private var statusBox: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("outbound delay: \(container.active.outboundDelayMs) ms")
                .modifier(MonoBodySmall())
            Text("outbound drop: \(formatPct(container.active.outboundLossRatio))")
                .modifier(MonoBodySmall())
            Text("inbound drop: \(formatPct(container.active.inboundLossRatio))")
                .modifier(MonoBodySmall())
            Text("offline: \(container.active.offline ? "true" : "false")")
                .modifier(MonoBodySmall())
            // W317: stub disclaimer — make it explicit that the UI is
            // not yet wired to a real packet shaper. Avoids the QA
            // tester wondering 'why doesn't this affect my call'.
            Text("⚠️ stub UI — packet shaper non ancora wired sul transport")
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundStyle(extras.warning)
                .padding(.top, 6)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(scheme.surfaceVariant.opacity(0.5))
        )
    }

    // MARK: - Helpers

    private func formatPct(_ ratio: Double) -> String {
        return String(format: "%.0f%%", ratio * 100.0)
    }
}

private struct MonoBodySmall: ViewModifier {
    @Environment(\.qaudionScheme) private var scheme
    func body(content: Content) -> some View {
        content
            .font(.system(size: 13, weight: .regular, design: .monospaced))
            .foregroundStyle(scheme.onSurface)
    }
}

#Preview {
    NavigationStack {
        NetworkSimulatorScreen()
    }
    .qAudionTheme(dark: true)
}
