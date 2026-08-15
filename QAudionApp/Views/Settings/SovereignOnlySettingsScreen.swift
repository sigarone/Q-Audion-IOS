import SwiftUI
import QAudionEngine

/// The screen for the sovereign-only video policy.
///
/// The policy itself has been fully implemented on iOS for a long time —
/// `CallsGate.sovereignOnlyEnabled`, `filterAdvertisedCapabilities` (which
/// strips `vkey-v1`) and `shouldRejectIncomingVideo` all exist and are
/// consumed by CallService and AppState. What did not exist was any way to
/// turn it on: a repo-wide search for `setSovereignOnly` returned exactly
/// one hit, its own definition. The flag was pinned at its `false` default
/// for the life of every install.
///
/// A single toggle and nothing else. No intro paragraph explaining what
/// sovereign audio is: that is stated continuously in-call by the trust
/// badge, which is where the user is actually deciding whether to trust the
/// call, rather than in prose on a settings screen they visit once.
struct SovereignOnlySettingsScreen: View {
    @ObservedObject var appState: AppState

    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType) private var type

    /// Local mirror of the Keychain-backed flag. `CallsGate` exposes it as
    /// a static get-only computed property while `SettingsToggleRow` wants a
    /// `Binding<Bool>`, so the binding writes through to `setSovereignOnly`
    /// and this holds the displayed state — the same shape the shipped
    /// callKitFreeMode row in CallsSettingsScreen already uses.
    @State private var sovereignOnly = false

    var body: some View {
        ZStack {
            scheme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SettingsSectionHeader("VIDEO")

                    VStack(spacing: 8) {
                        SettingsToggleRow(
                            title: "Modalità Solo-sovrano",
                            subtitle: "Disabilita il video cifrato sul telefono",
                            isOn: Binding(
                                get: { sovereignOnly },
                                set: { newValue in
                                    // Capabilities are negotiated when a call
                                    // is built, so flipping this mid-call
                                    // would desynchronise the advertised set
                                    // from the gate. The row is .disabled
                                    // below; this is the defence in depth.
                                    guard !appState.isInCall else { return }
                                    // No redundant Keychain write on a
                                    // no-op set.
                                    guard newValue != sovereignOnly else { return }
                                    sovereignOnly = newValue
                                    CallsGate.setSovereignOnly(newValue)
                                }
                            )
                        )
                        .disabled(appState.isInCall)

                        if appState.isInCall {
                            hint("Non modificabile durante una chiamata: le capability sono negoziate all'avvio, la modifica vale dalla prossima chiamata.")
                        }

                        hint(sovereignOnly
                             ? "Attiva. Questo dispositivo non offre il video cifrato a livello telefono e rifiuta il video in arrivo: con i contatti che non dispongono di chiavi sovrane le chiamate restano solo audio."
                             : "Non attiva. Il video usa le chiavi derivate dal telefono quando non sono disponibili chiavi sovrane.")
                    }

                    Spacer().frame(height: 24)
                }
                .padding(.horizontal, 16)
            }
        }
        .navigationTitle("Solo-sovrano")
        .onAppear {
            sovereignOnly = CallsGate.sovereignOnlyEnabled
        }
    }

    private func hint(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(scheme.onSurfaceVariant)
                .padding(.top, 1)
                .accessibilityHidden(true)
            Text(text)
                .qaudionStyle(type.labelSmall)
                .foregroundStyle(scheme.onSurfaceVariant)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(scheme.surfaceVariant.opacity(0.4))
        )
    }
}
