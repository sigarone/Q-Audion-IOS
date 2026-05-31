import Foundation

extension ReleaseNote {
    /// User-facing changelog. Aggiornare a ogni release con funzionalità
    /// visibili all'utente. Niente codici interni, tool o dettagli di build.
    public static let releaseNotes: [ReleaseNote] = [
        .init(id: "v1.0.560+", date: "2026-05-31",
              title: "Profilo e impostazioni",
              bullets: [
                "Esci direttamente dalla schermata Profilo",
                "Caller ID: supporto prefisso internazionale (+39…)",
                "Gestione chiavi: lista chiavi vault con fingerprint e scansione QR contatto",
                "Toggle Deepfake Guard / Re-keying / Padding ora effettivi",
                "Preset audio chiamate fisso a 32 kbps CBR per compatibilità cross-platform",
              ]),
        .init(id: "v1.0.550+", date: "2026-05-27",
              title: "Qualità audio",
              bullets: [
                "Elaborazione audio (AEC/NS/AGC) disattivata di default — meno artefatti",
                "Risparmio dati: qualità codec ridotta su rete cellulare",
                "Rilevamento deepfake live durante le chiamate",
              ]),
        .init(id: "v1.0.520+", date: "2026-05-15",
              title: "Video e compatibilità Android",
              bullets: [
                "Chiamate video HEVC tra iOS e Android",
                "Bitrate video adattivo su rete degradata",
                "Note vocali compatibili con Android e Desktop",
                "Scoperta contatti per numero di telefono allineata con Android",
              ]),
        .init(id: "v1.0.500+", date: "2026-05-10",
              title: "Gruppo e sicurezza post-quantum",
              bullets: [
                "Chiamate di gruppo N-way con audio Opus cifrato",
                "Chat di gruppo end-to-end",
                "Post-quantum ML-KEM-1024 su tutte le chiamate 1:1",
                "Verifica identità SAS con 6 parole — persiste tra sessioni",
              ]),
        .init(id: "v1.0.450+", date: "2026-05-05",
              title: "Diagnostica",
              bullets: [
                "Log runtime condivisibile per bug report",
                "Telemetria automatica (opt-in) per analisi da remoto",
                "Test banner e aptico in Impostazioni → Notifiche",
              ]),
        .init(id: "v1.0.400+", date: "2026-05-02",
              title: "Privacy e trasporto",
              bullets: [
                "TURN relay configurabile",
                "Presenza contatti: off = nessun punto verde visibile ai contatti",
                "Conferme di lettura, typing, anteprima messaggi — tutti effettivi",
                "Ore silenziose per notifiche",
                "Messaggi offline consegnati al riconnettere",
              ]),
    ]
}
