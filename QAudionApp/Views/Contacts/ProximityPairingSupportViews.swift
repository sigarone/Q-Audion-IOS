import SwiftUI
import QAudionEngine

// W-PAIRFB (2026-09) — in-person (QR + Bluetooth) pairing feedback sweep.
// Audit findings this file addresses: no in-app explanation of the 6-digit
// code, no clear final screen telling the three ways a pairing can end, no
// one-time "Novità" hint pointing at the feature after the update that
// shipped it. UI/UX only — the pairing protocol, crypto and wire format are
// untouched; see docs/security/PROXIMITY_PAIRING_QR_BLE_SPEC.md.

// MARK: - Telemetry

/// Privacy-safe lifecycle telemetry for the in-person pairing ceremony,
/// through the SAME `TelemetryService.emit` pipeline (consent-gated,
/// encrypted batch, `LogRedactor.redactStructured` scrub on every string
/// attribute) `CallMediaTelemetry` already uses. Before this, a pairing left
/// only on-device logs — the maintainer had no way to see on the server
/// that one happened, or why it failed (audit finding).
///
/// Every attribute is a closed enum token or a small integer count: no ids,
/// keys, SAS digits or names ever reach this file, let alone the server —
/// the engine-side `ProximityPairingTelemetryEvent` this forwards already
/// enforces that contract, and `ProximityOutcome.Kind` (the one extra piece
/// this file adds, from the app layer) is the same kind of closed enum.
enum ProximityPairingTelemetry {
    private static let startedKind = "pairing.proximity.started"
    private static let completedKind = "pairing.proximity.completed"
    private static let failedKind = "pairing.proximity.failed"
    private static let cancelledKind = "pairing.proximity.cancelled"

    /// Forwards an engine-reported lifecycle event. Pass this directly as a
    /// pairing screen's `onTelemetryEvent` closure.
    static func emit(_ event: ProximityPairingTelemetryEvent) {
        switch event {
        case .started(let role):
            forward(kind: startedKind, attrs: ["role": role.rawValue])
        case .failed(let cause, let stage):
            forward(kind: failedKind, attrs: [
                "cause": cause.rawValue,
                "stage": stage.rawValue
            ])
        case .cancelled(let stage):
            forward(kind: cancelledKind, attrs: ["stage": stage.rawValue])
        }
    }

    /// `TelemetryService.shared` is main-actor isolated; the emit itself is safe from any thread,
    /// so the (string-only) event is handed to the main actor here.
    private static func forward(kind: String, attrs: [String: String]) {
        Task { @MainActor in
            TelemetryService.shared.emit(kind: kind, attrs: attrs)
        }
    }

    /// A scanned text that is not a usable pairing code never reaches a
    /// pairing session, so the engine reports nothing for it: the scanner
    /// emits the failure itself. `cause` is Android's `invalid_qr` for both
    /// kinds of rejection; `reason` (a `ProximityQrRejection` token) tells
    /// them apart. No part of the scanned text is ever attached.
    static func emitScanRejected(reason: ProximityQrRejection) {
        forward(kind: failedKind, attrs: [
            "cause": ProximityPairingTelemetryEvent.FailureCause.invalidQrCode.rawValue,
            "stage": ProximityPairingTelemetryEvent.Stage.scanning.rawValue,
            "reason": reason.rawValue
        ])
    }

    /// The app layer emits `completed` itself, not the engine: only
    /// `ContactsListContainer.recordProximityPairing` knows whether the peer
    /// was already a known contact, which the `outcome` attribute needs.
    static func emitCompleted(outcome: ContactsListContainer.ProximityOutcome.Kind,
                              serverCheck: ProximityServerCheckOutcome,
                              elapsedMs: Int) {
        let outcomeRaw: String = outcome.rawValue
        let serverCheckRaw: String = serverCheck.rawValue
        Task { @MainActor in
            TelemetryService.shared.emit(kind: completedKind, attrs: [
                "outcome": outcomeRaw,
                "server_check": serverCheckRaw,
                "ms": elapsedMs
            ])
        }
    }
}

// MARK: - Rejected scans

/// What a scanner tells the user, the log and the telemetry about a text it
/// turned down. Both scanners that read pairing codes (`QrScannerSheet` and
/// the pairing-only `ProximityPairingScanScreen`) go through this, so the
/// words are the same wherever the code was scanned.
enum ProximityScanMessages {
    /// A QR that is not a pairing code at all (an identity, a link ...).
    static var notPairing: String {
        String(localized: "proximity.scan.not_pairing",
        defaultValue: "Questo QR non è un codice di associazione. Sull'altro telefono apri Contatti → Associa di persona → Mostra il mio codice.",
        comment: "Shown when the in-person pairing scanner reads a QR that is not a pairing code; tells where the other phone shows the right one")
    }

    /// A pairing code that fails the strict decoding.
    static var invalid: String {
        String(localized: "proximity.scan.invalid",
        defaultValue: "Questo non è un codice di associazione Q-Audion valido.",
        comment: "Shown when the in-person pairing scanner reads a pairing code that is damaged or not valid")
    }
}

/// One log line and one telemetry event per rejected scan. Only the closed
/// outcome and reason tokens and the length of the text leave the scanner:
/// never the text, an id or a key.
enum ProximityScanReport {
    static func notPairing(textLength: Int) {
        RTLog.info("pair", "scan outcome=not_pair len=\(textLength)")
        ProximityPairingTelemetry.emitScanRejected(reason: .notPairPrefix)
    }

    static func invalid(_ reason: ProximityQrRejection, textLength: Int) {
        RTLog.info("pair", "scan outcome=invalid reason=\(reason.rawValue) len=\(textLength)")
        ProximityPairingTelemetry.emitScanRejected(reason: reason)
    }
}

// MARK: - "Novità" one-time entry-point hint

/// Tracks whether the user has already opened the in-person pairing screen
/// since this feature's feedback sweep shipped, so its entry points (the
/// "Associa di persona" button of the Contacts tab, the legacy "+" menu row)
/// can carry a one-time "Novità" marker until they do (audit finding: the
/// feature was never announced). Independent of `WhatsNewData.swift`'s
/// changelog entry — that is opt-in browsing; this is the proactive nudge.
enum ProximityEntryPointHint {
    private static let seenKey = "qaudion.proximity.entryPointHintSeenV1"

    static var isUnseen: Bool {
        !UserDefaults.standard.bool(forKey: seenKey)
    }

    /// Call once the user actually opens the pairing screen (either role).
    static func markSeen() {
        UserDefaults.standard.set(true, forKey: seenKey)
    }

    /// The marker itself, for an entry point that shows it as a badge next to
    /// its own title (`menuTitle` carries it inside one string).
    static var badgeTitle: String {
        String(localized: "proximity.entry.badge_new",
        defaultValue: "Novità",
        comment: "Small badge on the Contacts tab's 'Pair in person' button until the user has opened the pairing screen once")
    }

    /// The legacy Contacts "+" menu row title: the ordinary label, plus a
    /// one-time "Novità" marker appended until `markSeen()` has run once.
    static var menuTitle: String {
        let base = String(localized: "proximity.entry.menu_title",
            defaultValue: "Associa di persona (QR + Bluetooth)",
            comment: "Contacts '+' menu row title for in-person pairing (QR code + Bluetooth)")
        guard isUnseen else { return base }
        return String(localized: "proximity.entry.menu_title_new",
            defaultValue: "Associa di persona (QR + Bluetooth) · Novità",
            comment: "Contacts '+' menu row for in-person pairing, with a one-time 'New' marker shown until the user opens the screen once after the update that added this row's feedback (verified badge, explanation, telemetry)")
    }
}

// MARK: - "Come funziona" explanation

/// One-time explanation of the in-person pairing ceremony (audit finding:
/// "no in-app explanation of what the 6 digits are and why it is secure").
/// Reachable any time via the info button `ProximityPairingSheet.swift`
/// adds to the pairing screen's toolbar, and shown automatically the first
/// time that screen opens (`ProximityHowItWorks.presentOnFirstUse`).
enum ProximityHowItWorks {
    private static let seenKey = "qaudion.proximity.howItWorksSeenV1"

    /// Whether the explanation should auto-present right now — true only
    /// the very first time a pairing screen appears. Does NOT itself mark
    /// it seen; the caller does that once the sheet is actually shown, so a
    /// screen that fails to appear (e.g. torn down before `onAppear` runs)
    /// does not silently burn the one-time slot.
    static var presentOnFirstUse: Bool {
        !UserDefaults.standard.bool(forKey: seenKey)
    }

    static func markSeen() {
        UserDefaults.standard.set(true, forKey: seenKey)
    }

    static var title: String {
        String(localized: "proximity.howitworks.title",
        defaultValue: "Come funziona",
        comment: "Title of the in-person (QR + Bluetooth) pairing explanation sheet, and the info button that reopens it")
    }

    static var body: String {
        String(localized: "proximity.howitworks.body",
        defaultValue: "L'altro telefono mostra o scansiona il codice QR.\n\nI telefoni si collegano da soli via Bluetooth: non c'è nulla da configurare.\n\nLeggete ad alta voce le 6 cifre mostrate su entrambi gli schermi: devono coincidere.\n\nLe 6 cifre servono a scoprire chi provasse a mettersi in mezzo allo scambio — se non coincidono, annullate.\n\nLo scambio usa crittografia post-quantistica ibrida (ML-KEM-1024 + X25519): nulla lascia i due telefoni in chiaro.\n\nLa chiave così creata resta sui vostri telefoni e protegge le chiamate tra voi da questo momento in poi.",
        comment: "Body text of the in-person (QR + Bluetooth) pairing explanation sheet, plain language, one blank line between each of the 6 points: (1) show/scan the QR, (2) phones connect over Bluetooth by themselves, (3) compare the 6 digits out loud, (4) why the 6 digits matter (catch a man-in-the-middle), (5) the crypto used and that nothing leaves the phones unencrypted, (6) what the resulting key protects")
    }
}

/// The explanation sheet itself. A plain, self-contained SwiftUI view (no
/// design-system dependency) so it can be presented from either of the two
/// Contacts screens or from `QrScannerSheet` without threading extra
/// environment values through.
struct ProximityHowItWorksSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Image(systemName: "qrcode.viewfinder")
                        .font(.system(size: 40))
                        .foregroundStyle(.blue)
                    Text(ProximityHowItWorks.body)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(ProximityHowItWorks.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fatto") { dismiss() }
                }
            }
        }
    }
}

/// Small toolbar info button that presents `ProximityHowItWorksSheet`.
/// Embedded by `ProximityPairingSheet.swift` so every entry point (Contacts
/// FAB, QR scanner) gets it for free.
struct ProximityHowItWorksButton: View {
    @State private var showing = false

    var body: some View {
        Button {
            showing = true
        } label: {
            Image(systemName: "info.circle")
        }
        .accessibilityLabel(ProximityHowItWorks.title)
        .sheet(isPresented: $showing) {
            ProximityHowItWorksSheet()
        }
    }
}

// MARK: - Final outcome screen

/// A clear final screen distinguishing the three (four, counting the rare
/// failure-to-add edge case) ways an in-person pairing can end — audit
/// finding: previously just a transient toast, easy to miss and impossible
/// to distinguish "verified" from "merely saved" at a glance.
struct ProximityOutcomeResultSheet: View {
    let outcome: ContactsListContainer.ProximityOutcome
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Spacer(minLength: 12)
                Image(systemName: iconName)
                    .font(.system(size: 64))
                    .foregroundStyle(iconColor)
                Text(outcome.title)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text(outcome.detail)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Spacer()
                Button(action: onDone) {
                    Text("Fatto")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
            }
            .padding(.horizontal, 24)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Chiudi") { onDone() }
                }
            }
        }
    }

    private var iconName: String {
        switch outcome.kind {
        case .newContactVerified: return "checkmark.seal.fill"
        case .existingContact: return "checkmark.circle.fill"
        case .savedUnverified: return "exclamationmark.triangle.fill"
        case .notAdded: return "exclamationmark.circle.fill"
        }
    }

    private var iconColor: Color {
        switch outcome.kind {
        case .newContactVerified, .existingContact: return .green
        case .savedUnverified: return .orange
        case .notAdded: return .red
        }
    }
}
