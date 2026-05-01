import SwiftUI
import QAudionEngine

/// W49: "Cosa c'è di nuovo" — changelog viewer per i tester TestFlight.
/// Hardcoded list di release entries (tag + data + bullet di feature)
/// così non serve un fetch network e non c'è dipendenza dall'engine.
/// Pensato per essere aggiornato manualmente a ogni tag — l'autore della
/// release deve aggiungere un nuovo `ReleaseNote` in `releaseNotes` qui
/// sotto. Non sostituisce l'OTA catalog (W42), che gestisce release
/// firmate Ed25519; questo è puramente informativo.
public struct ReleaseNote: Identifiable, Equatable {
    public let id: String   // tag, es. "v1.0.96"
    public let date: String // ISO short, es. "2026-04-30"
    public let title: String
    public let bullets: [String]

    public init(id: String, date: String, title: String, bullets: [String]) {
        self.id = id; self.date = date; self.title = title; self.bullets = bullets
    }
}

extension ReleaseNote {
    /// Hardcoded changelog. Più recenti in alto. Aggiornare a ogni tag.
    public static let releaseNotes: [ReleaseNote] = [
        .init(id: "v1.0.255", date: "2026-05-01",
              title: "Fix type-checker timeout #3 — String(Int) overload trap (W255)",
              bullets: [
                "ChatDetailScreen.swift:175 — `String(rec.durationMs)` (Int) also times out",
                "Root cause: String(_:) has many numeric overloads (Int, UInt, Double, …)",
                "Fix: switch to String(describing:) which has a single overload",
                "CLAUDE.md §13 updated with this 3rd type-checker antipattern variant"
              ]),
        .init(id: "v1.0.253", date: "2026-05-01",
              title: "Fix type-checker timeout #2 in ChatDetailScreen (W253)",
              bullets: [
                "ChatDetailScreen.swift:151 — print(\"...\" + errMsg) still tripped the type-checker",
                "Even with errMsg pre-bound, the `+` operator inside `print(...)` was the problem",
                "`print` has many overloads (variadic / separator / terminator / to:&Output)",
                "Fix: build full line into a local String, then `print(line)`",
                "Same pattern as onFinishVoiceNote (lines 169-175) — now consistent"
              ]),
        .init(id: "v1.0.252", date: "2026-05-01",
              title: "Quick-copy build identifier in About (W179)",
              bullets: [
                "About → ASSISTENZA: nuovo bottone 'Copia diagnostica rapida'",
                "Copia in clipboard: versione · build · dispositivo · iOS",
                "Sister di 'Contatta supporto' — stesso payload, transport diverso",
                "Useful per Slack/Discord/issue trackers senza aprire Mail"
              ]),
        .init(id: "v1.0.251", date: "2026-05-01",
              title: "Fix type-checker timeout in ChatDetailScreen (W251)",
              bullets: [
                "ChatDetailScreen.swift:197 W38 send-failure snackbar — multi-segment interpolation `\\(reason.localizedDescription)` triggered Swift 6 / Xcode 26.4 type-checker timeout",
                "Fix: pre-bind reason.localizedDescription to local + use String + concatenation",
                "Same defensive treatment applied to typingRow (peer display-name chain)",
                "Cross-references CLAUDE.md §13 — type-checker traps documented in W174"
              ]),
        .init(id: "v1.0.241–249", date: "2026-05-01",
              title: "QA toolkit polish + CI diagnostics (W170–W177)",
              bullets: [
                "About → PIATTAFORMA: dispositivo + iOS in uso (W170)",
                "Notifiche → DIAGNOSTICA: invio notifica di test (W171)",
                "Footnote copyright sotto la versione (W172)",
                "About → ASSISTENZA: contatta supporto via mail (W173)",
                "CLAUDE.md: documentazione type-checker traps (W174)",
                "CI: profiling flags compile-time per surfacciare bottleneck (W175)",
                "CI: re-print diag.log all'inizio di Step 7 per visibilità (W177)"
              ]),
        .init(id: "v1.0.232–238", date: "2026-05-01",
              title: "Diagnostica e dev tools (W162–W167)",
              bullets: [
                "About: 'Build installato N giorni fa' (W162)",
                "Settings → SVILUPPATORE: Reset metadati locali (W163)",
                "Diagnostic export: conta abbozzi · ultimo accesso · build seen (W164)",
                "Conferma prima di Svuota cache allegati (W165)",
                "Pulisci badge notifiche dev action (W166)",
                "About → CONNESSIONE: stato WS live + autenticato (W167)"
              ]),
        .init(id: "v1.0.220–231", date: "2026-05-01",
              title: "Privacy & polish marathon (W137–W160)",
              bullets: [
                "Abbozzi composer persistenti per chat (W137) + indicatore \"Bozza:\" (W138)",
                "Esporta chat in .txt via share sheet (W139)",
                "Swipe \"Segna letto\" e azioni di contesto sulla lista (W140)",
                "Finestra modifica messaggi 15 minuti (W141)",
                "\"Ultimo accesso\" del peer in topbar chat (W142)",
                "Banner E2E nelle chat vuote (W143)",
                "Velocità voice-note persistente tra sessioni (W144)",
                "Conferma prima di Elimina/Svuota/Esci (W145, W147, W151)",
                "Conteggio non letti nel titolo \"Chat (N)\" (W146)",
                "Markdown inline `code` / **bold** / *italic* nei bubble (W148, W149)",
                "Cancella abbozzi + ultimo accesso da Settings (W150, W153)",
                "Toggle privacy: anteprima link (W152), abbozzi nella lista (W155), vibrazione (W160)",
                "Tap-to-copy versione + ID utente (W156, W157)",
                "About: \"Membro da\" + dati locali (conversazioni, messaggi, abbozzi) (W158, W159)"
              ]),
        .init(id: "v1.0.96", date: "2026-04-30",
              title: "QA toolkit completata",
              bullets: [
                "Esporta diagnostica — text dump shareable con build, device, state (no token leak)",
                "Sister di Reset dati locali (v1.0.94) per workflow QA TestFlight"
              ]),
        .init(id: "v1.0.95", date: "2026-04-30",
              title: "CallHistory gesture",
              bullets: [
                "Swipe-trailing su una chiamata → Elimina (gesto Mail/Messages canonico)",
                "Overflow menu nel topBar → Cancella storico con alert di conferma + count"
              ]),
        .init(id: "v1.0.94", date: "2026-04-30",
              title: "Reset dati locali",
              bullets: [
                "Settings → SVILUPPATORE → Reset dati locali",
                "Wipe di 8 chiavi UserDefaults non-credenziale (numeri, opt-in beta, banner)",
                "Auth token / device id preservati (logout esplicito separato)"
              ]),
        .init(id: "v1.0.93", date: "2026-04-30",
              title: "Group composer real",
              bullets: [
                "FAB \"Nuovo gruppo\" nella tab Chiamate ora apre il vero CreateGroupScreen",
                "Rimosso lo stub \"W40 in arrivo\" (W40 è già live da v1.0.86)"
              ]),
        .init(id: "v1.0.92", date: "2026-04-30",
              title: "I miei numeri (multi-phone)",
              bullets: [
                "Settings → ACCOUNT → I miei numeri",
                "Multipli E.164 attaccati allo stesso account (peppered hash)",
                "Validazione E.164 client-side via PhoneHashHelper"
              ]),
        .init(id: "v1.0.91", date: "2026-04-29",
              title: "Hotfix critico + W42 + W43 + W39.polish",
              bullets: [
                "FIX: HomeView mancava `}` su callsTab — sbloccato build TestFlight",
                "FIX: FastSetup login E.164 double-hash — `loginWithPhoneHash` bypass",
                "Aggiornamento OTA stub UI in Settings → INFO",
                "Simulatore rete (dev) in Settings → SVILUPPATORE",
                "CallHistory encapsulation polish"
              ]),
        .init(id: "v1.0.86–88", date: "2026-04-28",
              title: "Group Chat trio + DeviceManagement",
              bullets: [
                "CreateGroupScreen + GroupChatScreen + GroupInfoScreen (W40)",
                "DeviceManagementScreen enhanced + LinkNewDeviceScreen X25519",
                "BubbleActionSheet snackbar feedback per le 4 azioni chat"
              ]),
        .init(id: "v1.0.66–85", date: "2026-04-26",
              title: "Cross-platform parity track A",
              bullets: [
                "ChatListScreen sectioned (W19) — 1:1 con Android",
                "ContactsScreen W23 — TUTTI / SCOPRI / BLOCCATI",
                "SettingsScreen W24 — ProfileHero + SecurityChips + 6 sezioni",
                "CallHistoryView W39 — call-history list",
                "Onboarding stack — Splash + Welcome + PhoneEntry + VoiceEnrollment + FastSetup"
              ]),
    ]
}

struct WhatsNewScreen: View {
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType) private var type

    var body: some View {
        ZStack {
            scheme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    intro
                    ForEach(ReleaseNote.releaseNotes) { note in
                        releaseCard(note)
                    }
                    Spacer().frame(height: 24)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }
        }
        .navigationTitle("Cosa c'è di nuovo")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Intro

    private var intro: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("CHANGELOG")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .tracking(1.5)
                .foregroundStyle(scheme.primary)
            Text("Lista delle ultime release TestFlight con i cambiamenti principali. Aggiornata manualmente a ogni tag — la versione canonica del changelog vive nel repository git su `feature/ios-android-parity`.")
                .qaudionStyle(type.bodySmall)
                .foregroundStyle(scheme.onSurface)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(scheme.surfaceVariant.opacity(0.5))
        )
    }

    // MARK: - Release card

    private func releaseCard(_ note: ReleaseNote) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(note.id)
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                    .foregroundStyle(scheme.onSurface)
                Spacer(minLength: 0)
                Text(note.date)
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundStyle(scheme.onSurfaceVariant)
            }
            Text(note.title)
                .qaudionStyle(type.titleSmall)
                .fontWeight(.semibold)
                .foregroundStyle(scheme.primary)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(note.bullets, id: \.self) { bullet in
                    HStack(alignment: .top, spacing: 6) {
                        Text("•")
                            .foregroundStyle(scheme.primary)
                        Text(bullet)
                            .qaudionStyle(type.bodySmall)
                            .foregroundStyle(scheme.onSurface)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(scheme.surfaceVariant.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(scheme.outline.opacity(0.4), lineWidth: 1)
        )
    }
}

#Preview {
    NavigationStack {
        WhatsNewScreen()
    }
    .qAudionTheme(dark: true)
}
