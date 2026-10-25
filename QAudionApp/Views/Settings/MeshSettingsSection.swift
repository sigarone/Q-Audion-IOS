import SwiftUI
import QAudionEngine

/// Settings > Privacy controls > "Mesh Bluetooth": shows, and changes, whether this phone may relay the encrypted messages
/// of other app users over Bluetooth (the one-time consent).
///
/// On shows the consent to relay as accepted. Turning it on from here opens the same consent screen as the first run, and
/// nothing starts until the user answers it; turning it off records that relaying is not allowed: a running radio drops to
/// direct mode (it still finds nearby contacts and exchanges the user's own messages, and forwards nothing), and the antenna
/// itself is turned off from the mesh panel of a chat.
/// Shown unless the remote kill switch `mesh_ble.enabled` has been set to false (the feature ships on).
///
/// The switch is the consent, not the antenna: a user who accepted and then turned the antenna off in the mesh panel still
/// sees the switch on. So the subtitle says what the radio is actually doing (`MeshSettingsStatus`), instead of leaving the
/// switch to suggest that this phone is relaying.
///
/// Takes no AppState (CLAUDE.md section 16): the state is `MeshConsent`, the radio is `MeshRuntime`.
struct MeshSettingsSection: View {
    @ObservedObject private var consent = MeshConsent.shared
    /// The radio: the subtitle follows its state.
    @ObservedObject private var runtime = MeshRuntime.shared
    /// Whether a call is busy (mirrored by the root): the consent screen is never presented over one.
    @ObservedObject private var arbiter = MeshConsentArbiter.shared
    @State private var showingConsent: Bool = false
    @State private var showingRelayAlert: Bool = false

    var body: some View {
        if MeshFeature.enabled {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(Self.sectionTitle)
            VStack(spacing: 8) {
                SettingsToggleRow(
                    title: Self.rowTitle,
                    subtitle: subtitle,
                    isOn: meshBinding
                )
            }
        }
        .meshConsentSheet(
            wanted: $showingConsent,
            callBusy: arbiter.callBusy,
            onContinue: continueAfterPriming
        )
        .meshRelayAlert(isPresented: $showingRelayAlert) {
            MeshRuntime.shared.acceptConsentAndStart()
        }
    }

    /// What the radio is doing, in plain words, next to the consent the switch shows (`MeshSettingsStatus`).
    private var subtitle: String {
        let status: MeshSettingsStatus = MeshSettingsStatus.resolve(
            consent: consent.state,
            antennaOn: runtime.antennaOn,
            mode: runtime.antennaMode)
        switch status {
        case .notAllowed: return Self.rowSubtitle
        case .radioOff: return Self.statusRadioOff
        case .visibleOnly: return Self.statusVisibleOnly
        case .direct: return Self.statusDirect
        case .on: return Self.statusOn
        }
    }

    /// The switch IS the consent to relay: it reads on only after "Consenti" in the relay alert. Turning it on never changes
    /// the state by itself: before the first answer it opens the screen that leads to the Bluetooth permission request, after
    /// it the relay alert; turning it off records "declined" and drops a running radio to direct mode.
    private var meshBinding: Binding<Bool> {
        Binding(
            get: { consent.isAccepted },
            set: { turnOn in
                if turnOn {
                    if consent.state == .undecided { showingConsent = true } else { showingRelayAlert = true }
                } else {
                    // Relaying off; a running radio drops to direct mode, an antenna that is off stays off.
                    MeshRuntime.shared.declineRelayAndUseDirect(startIfOff: false)
                }
            }
        )
    }

    private func continueAfterPriming() {
        showingConsent = false
        MeshRuntime.shared.continueAfterPriming()
    }

    private static var sectionTitle: String { String(localized: "mesh_settings.section", defaultValue: "MESH BLUETOOTH", comment: "Header of the Bluetooth mesh section in Settings > Privacy controls.") }
    private static var rowTitle: String { String(localized: "mesh_settings.title", defaultValue: "Mesh Bluetooth", comment: "Title of the switch that lets this phone relay encrypted messages of nearby app users over Bluetooth.") }
    private static var rowSubtitle: String { String(localized: "mesh_settings.subtitle", defaultValue: "Inoltra via Bluetooth i messaggi cifrati di chi ti sta vicino. Non può leggerli.", comment: "Subtitle of the Bluetooth mesh switch in Settings: this phone relays encrypted messages of nearby app users and cannot read them.") }
    private static var statusRadioOff: String { String(localized: "mesh_settings.status_radio_off", defaultValue: "La mesh è spenta: la accendi dal pannello mesh di una chat.", comment: "Subtitle of the Bluetooth mesh switch in Settings when the consent screen was answered but the antenna is off: it is turned on from the mesh panel of a chat.") }
    private static var statusVisibleOnly: String { String(localized: "mesh_settings.status_visible_only", defaultValue: "Il telefono è visibile ai vicini, ma non apre collegamenti e non inoltra messaggi.", comment: "Subtitle of the Bluetooth mesh switch in Settings when the antenna is on in visible-only mode: nearby phones can see this one, it opens no connections and relays nothing.") }
    private static var statusDirect: String { String(localized: "mesh_settings.status_direct", defaultValue: "Il telefono trova i contatti vicini e scambia i tuoi messaggi con loro, senza inoltrare quelli degli altri.", comment: "Subtitle of the Bluetooth mesh switch in Settings when the user did not allow relaying and the antenna is on in direct mode: this phone finds nearby contacts and exchanges the user's own messages with them, relaying nothing.") }
    private static var statusOn: String { String(localized: "mesh_settings.status_on", defaultValue: "La mesh è accesa: questo telefono inoltra i messaggi cifrati di chi ti sta vicino.", comment: "Subtitle of the Bluetooth mesh switch in Settings when the user allowed relaying and the antenna is on in full mesh mode: this phone relays encrypted messages of nearby app users.") }
}
