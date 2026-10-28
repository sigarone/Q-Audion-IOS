import Foundation

/// Every label of the terms acceptance, withdrawal and legal screens. The legal texts themselves are never here: they
/// come from the server (`GET /api/v1/legal/terms`). Each string lives in the String Catalog (it, en, de, fr, es, pt-BR).
enum LegalStrings {
    static var termsCheckbox: String {
        String(localized: "legal.terms.checkbox", defaultValue: "Ho letto e accetto i Termini e condizioni e l'Informativa privacy", comment: "Terms acceptance: box that accepts the Terms and Conditions and the Privacy Policy.")
    }

    static var readTerms: String {
        String(localized: "legal.terms.read", defaultValue: "Leggi i Termini e condizioni", comment: "Terms acceptance: link that opens the full text of the Terms.")
    }

    static var readPrivacy: String {
        String(localized: "legal.privacy.read", defaultValue: "Leggi l'Informativa privacy", comment: "Terms acceptance: link that opens the Privacy Policy.")
    }

    static var specificCheckbox: String {
        String(localized: "legal.specific.checkbox", defaultValue: "Accetto espressamente le caratteristiche del servizio indicate all'art. 21.1-bis e approvo specificamente, ai sensi degli artt. 1341 e 1342 c.c., le clausole elencate", comment: "Terms acceptance: box that accepts art. 21.1-bis features and gives the specific approval of the listed clauses (arts. 1341-1342 of the Italian Civil Code).")
    }

    static var showSpecific: String {
        String(localized: "legal.specific.show", defaultValue: "Mostra", comment: "Terms acceptance: link next to the specific-approval box that shows the listed clauses.")
    }

    static var italianPrevails: String {
        String(localized: "legal.lang.prevails", defaultValue: "Il testo in lingua italiana prevale (art. 34).", comment: "Note under the legal texts when they are shown in English: the Italian text prevails (art. 34).")
    }

    static var loading: String {
        String(localized: "legal.loading", defaultValue: "Caricamento dei Termini…", comment: "Shown while the legal text is loaded from the server.")
    }

    static var loadFailed: String {
        String(localized: "legal.load_failed", defaultValue: "Impossibile caricare i Termini. Controlla la connessione e riprova.", comment: "Shown when the legal text could not be loaded from the server.")
    }

    static var retry: String {
        String(localized: "legal.retry", defaultValue: "Riprova", comment: "Button that repeats a failed load.")
    }

    static var gateTitle: String {
        String(localized: "legal.gate.title", defaultValue: "Termini aggiornati", comment: "Blocking screen for an existing account that must accept the updated Terms: title.")
    }

    static var gateMessage: String {
        String(localized: "legal.gate.message", defaultValue: "Per continuare a usare Q-Audion devi accettare i Termini e condizioni aggiornati. Le chiamate in corso non vengono mai interrotte.", comment: "Blocking screen for an existing account that must accept the updated Terms: explanation.")
    }

    static var submitFailed: String {
        String(localized: "legal.gate.submit_failed", defaultValue: "Non è stato possibile registrare l'accettazione. Riprova.", comment: "Error under the acceptance screen: the acceptance was not sent.")
    }

    static var editionChanged: String {
        String(localized: "legal.gate.edition_changed", defaultValue: "I Termini sono stati aggiornati nel frattempo. Leggi il nuovo testo e accetta di nuovo.", comment: "Error under the acceptance screen: the Terms changed while the screen was open.")
    }

    static var withdrawRow: String {
        String(localized: "legal.withdraw.row", defaultValue: "Recedi dal contratto qui", comment: "Settings > Account: row that opens the withdrawal from the contract (art. 54-bis Italian Consumer Code).")
    }

    static var withdrawRowSubtitle: String {
        String(localized: "legal.withdraw.row_subtitle", defaultValue: "Art. 54-bis Codice del Consumo", comment: "Settings > Account: caption of the withdrawal row.")
    }

    static var withdrawTitle: String {
        String(localized: "legal.withdraw.title", defaultValue: "Recesso dal contratto", comment: "Withdrawal screen: title.")
    }

    static var withdrawConfirm: String {
        String(localized: "legal.withdraw.confirm", defaultValue: "Conferma recesso", comment: "Withdrawal screen: button that sends the withdrawal.")
    }

    static var withdrawWarning: String {
        String(localized: "legal.withdraw.warning", defaultValue: "Confermando, il contratto termina e il tuo account viene eliminato in modo permanente dal server e da questo dispositivo.", comment: "Withdrawal screen: what confirming does.")
    }

    static var withdrawSending: String {
        String(localized: "legal.withdraw.sending", defaultValue: "Invio del recesso…", comment: "Withdrawal screen: shown while the withdrawal is sent.")
    }

    static var withdrawFailed: String {
        String(localized: "legal.withdraw.failed", defaultValue: "Il recesso non è stato registrato. Riprova tra qualche istante o scrivi a info@bcrypto.com.", comment: "Withdrawal screen: the request failed.")
    }

    static var withdrawSessionEnded: String {
        String(localized: "legal.withdraw.session_ended", defaultValue: "La sessione non è più valida. Se il recesso è stato registrato, l'account è già stato eliminato. In caso di dubbio scrivi a info@bcrypto.com.", comment: "Withdrawal screen: the session is no longer valid.")
    }

    static var receiptTitle: String {
        String(localized: "legal.receipt.title", defaultValue: "Ricevuta di recesso", comment: "Receipt screen after a withdrawal: title.")
    }

    static var receiptKeep: String {
        String(localized: "legal.receipt.keep", defaultValue: "Conserva questa ricevuta: è la conferma del recesso su supporto durevole.", comment: "Receipt screen after a withdrawal: why to save it.")
    }

    static var termsUpdatedReview: String {
        String(localized: "legal.terms.updated_review", defaultValue: "I Termini sono stati aggiornati: leggili di nuovo, per favore.", comment: "Registration error: the Terms changed while the person was registering; the steps are shown again.")
    }

    static var receiptUnsavedTitle: String {
        String(localized: "legal.receipt.unsaved.title", defaultValue: "Non hai salvato la ricevuta", comment: "Receipt screen, closing without saving: title of the question.")
    }

    static var receiptUnsavedMessage: String {
        String(localized: "legal.receipt.unsaved.message", defaultValue: "Se chiudi senza salvarla, non ne resta una copia sul telefono.", comment: "Receipt screen, closing without saving: why saving first is better.")
    }

    static var receiptCloseAnyway: String {
        String(localized: "legal.receipt.unsaved.close", defaultValue: "Chiudi senza salvare", comment: "Receipt screen, closing without saving: button that closes anyway.")
    }

    static var receiptSave: String {
        String(localized: "legal.receipt.save", defaultValue: "Salva", comment: "Receipt screen: saves the receipt as a text file.")
    }

    static var receiptShare: String {
        String(localized: "legal.receipt.share", defaultValue: "Condividi", comment: "Receipt screen: shares the receipt as a text file.")
    }

    static var settingsTitle: String {
        String(localized: "legal.settings.title", defaultValue: "Legale", comment: "Settings: title of the legal section and its screen.")
    }

    static var settingsSubtitle: String {
        String(localized: "legal.settings.subtitle", defaultValue: "Termini, accettazione, avviso emergenze", comment: "Settings: caption of the legal row.")
    }

    static var settingsTerms: String {
        String(localized: "legal.settings.terms", defaultValue: "Termini e condizioni", comment: "Settings > Legal: opens the Terms and Conditions.")
    }

    static var settingsAcceptance: String {
        String(localized: "legal.settings.acceptance", defaultValue: "Copia della tua accettazione", comment: "Settings > Legal: opens the copy of what the user accepted.")
    }

    static var settingsEmergency: String {
        String(localized: "legal.settings.emergency", defaultValue: "Avviso sulle chiamate di emergenza", comment: "Settings > Legal: opens the emergency calls notice.")
    }

    static var editionFormat: String {
        String(localized: "legal.settings.edition", defaultValue: "Edizione %@", comment: "Settings > Legal: edition of the Terms; %@ is the version date.")
    }

    static var acceptanceNone: String {
        String(localized: "legal.acceptance.none", defaultValue: "Nessuna accettazione registrata per questo account.", comment: "Settings > Legal: no acceptance on record for the account.")
    }

    static var acceptanceFailed: String {
        String(localized: "legal.acceptance.failed", defaultValue: "Impossibile leggere la copia. Riprova tra qualche istante.", comment: "Settings > Legal: the copy could not be loaded.")
    }

    static var emergencyTitle: String {
        String(localized: "legal.emergency.title", defaultValue: "Chiamate di emergenza", comment: "Emergency calls notice: title.")
    }

    static func edition(_ version: String) -> String {
        String(format: LegalStrings.editionFormat, version)
    }
}
