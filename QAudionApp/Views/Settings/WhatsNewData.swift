import Foundation

extension ReleaseNote {
    /// User-facing changelog. Aggiornare a ogni release con funzionalità
    /// visibili all'utente. Niente codici interni, tool o dettagli di build.
    /// Computed (not a stored `static let`) so the text follows the in-app
    /// language switch; one helper per release keeps each expression small.
    public static var releaseNotes: [ReleaseNote] {
        [releaseNote1214, releaseNote1196, releaseNote560, releaseNote500]
    }

    private static var releaseNote1214: ReleaseNote {
        .init(id: "v1.0.1214+", date: "2026-10-09",
              title: String(localized: "whats_new.v1214.title", defaultValue: "Messaggi", comment: "What's new, release v1.0.1214 title"),
              bullets: [
                String(localized: "whats_new.v1214.b1", defaultValue: "Puoi rispondere a un messaggio specifico citandolo", comment: "What's new, release v1.0.1214 bullet: reply to a specific message by quoting it"),
              ])
    }

    private static var releaseNote1196: ReleaseNote {
        .init(id: "v1.0.1196+", date: "2026-09-30",
              title: String(localized: "whats_new.v1196.title", defaultValue: "Associazione di persona più chiara", comment: "What's new, release v1.0.1196 title"),
              bullets: [
                String(localized: "whats_new.v1196.b1", defaultValue: "Contatti → Aggiungi contatto → \"Associa di persona (QR + Bluetooth)\" ora spiega in una schermata come funziona e perché è sicuro, prima di iniziare", comment: "What's new, release v1.0.1196 bullet: the in-person pairing entry now explains how it works on one screen; menu names must match the app's own labels"),
                String(localized: "whats_new.v1196.b2", defaultValue: "Il contatto associato di persona mostra ora un promemoria \"Verificato di persona\" con la data, nella scheda del contatto", comment: "What's new, release v1.0.1196 bullet: a contact paired in person shows a 'Verified in person' reminder with the date"),
                String(localized: "whats_new.v1196.b3", defaultValue: "Al termine, una schermata chiara distingue: nuovo contatto verificato, chiave aggiunta a un contatto già noto, oppure chiave salvata senza verifica server", comment: "What's new, release v1.0.1196 bullet: the end-of-pairing screen distinguishes three outcomes"),
              ])
    }

    private static var releaseNote560: ReleaseNote {
        .init(id: "v1.0.560+", date: "2026-05-31",
              title: String(localized: "whats_new.v560.title", defaultValue: "Profilo e impostazioni", comment: "What's new, release v1.0.560 title"),
              bullets: [
                String(localized: "whats_new.v560.b1", defaultValue: "Esci direttamente dalla schermata Profilo", comment: "What's new, release v1.0.560 bullet: sign out from the Profile screen"),
                String(localized: "whats_new.v560.b2", defaultValue: "Gestione chiavi: impronta dell'identità e scansione del QR di un contatto", comment: "What's new, release v1.0.560 bullet: key management shows the identity fingerprint and can scan a contact's QR code"),
              ])
    }

    private static var releaseNote500: ReleaseNote {
        .init(id: "v1.0.500+", date: "2026-05-10",
              title: String(localized: "whats_new.v500.title", defaultValue: "Chiamate e chat di gruppo", comment: "What's new, release v1.0.500 title"),
              bullets: [
                String(localized: "whats_new.v500.b1", defaultValue: "Chiamate di gruppo", comment: "What's new, release v1.0.500 bullet: group calls"),
                String(localized: "whats_new.v500.b2", defaultValue: "Chat di gruppo con cifratura end-to-end", comment: "What's new, release v1.0.500 bullet: end-to-end encrypted group chats"),
                String(localized: "whats_new.v500.b3", defaultValue: "Verifica dell'identità con parole SAS nelle chiamate 1:1", comment: "What's new, release v1.0.500 bullet: identity verification with SAS words in 1:1 calls"),
              ])
    }
}
