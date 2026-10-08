import Foundation

extension ReleaseNote {
    /// User-facing changelog. Aggiornare a ogni release con funzionalità
    /// visibili all'utente. Niente codici interni, tool o dettagli di build.
    public static let releaseNotes: [ReleaseNote] = [
        .init(id: "v1.0.1214+", date: "2026-10-09",
              title: "Messaggi e allegati",
              bullets: [
                "Puoi rispondere a un messaggio specifico citandolo",
                "Puoi inviare dalla chat foto, video e file di qualsiasi tipo",
              ]),
        .init(id: "v1.0.1196+", date: "2026-09-30",
              title: "Associazione di persona più chiara",
              bullets: [
                "Contatti → Aggiungi contatto → \"Associa di persona (QR + Bluetooth)\" ora spiega in una schermata come funziona e perché è sicuro, prima di iniziare",
                "Il contatto associato di persona mostra ora un promemoria \"Verificato di persona\" con la data, nella scheda del contatto",
                "Al termine, una schermata chiara distingue: nuovo contatto verificato, chiave aggiunta a un contatto già noto, oppure chiave salvata senza verifica server",
              ]),
        .init(id: "v1.0.560+", date: "2026-05-31",
              title: "Profilo e impostazioni",
              bullets: [
                "Esci direttamente dalla schermata Profilo",
                "Gestione chiavi: impronta dell'identità e scansione del QR di un contatto",
              ]),
        .init(id: "v1.0.500+", date: "2026-05-10",
              title: "Chiamate e chat di gruppo",
              bullets: [
                "Chiamate di gruppo",
                "Chat di gruppo con cifratura end-to-end",
                "Verifica dell'identità con parole SAS nelle chiamate 1:1",
              ]),
    ]
}
