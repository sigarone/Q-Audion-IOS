import Foundation

/// Texts of the device-approval flow: the waiting screen of a new device, the approval sheet, the prompt that
/// offers to disconnect the other devices, the account notices and the recovery contacts. Generated from one
/// table together with the String Catalog entries (it, en, es, fr, de, pt-BR).
enum DeviceApprovalTexts {
    static var waitTitle: String {
        String(localized: "login_approval.wait.title",
               defaultValue: "Conferma l'accesso",
               comment: "Waiting screen after a sign-in that needs approval: title.")
    }

    static func waitInstruction(_ code: String) -> String {
        String(localized: "login_approval.wait.instruction",
               defaultValue: "Conferma da un tuo altro dispositivo scegliendo il numero \(code)",
               comment: "Waiting screen: what to do on the other device. %@ is the two-digit number shown on this screen.")
    }

    static func waitCountdown(_ time: String) -> String {
        String(localized: "login_approval.wait.countdown",
               defaultValue: "Scade tra \(time)",
               comment: "Waiting screen: time left before the request expires. %@ is minutes and seconds, like 9:41.")
    }

    static var waitWaiting: String {
        String(localized: "login_approval.wait.waiting",
               defaultValue: "In attesa di conferma…",
               comment: "Waiting screen: status line while the answer has not arrived.")
    }

    static var waitConnection: String {
        String(localized: "login_approval.wait.connection",
               defaultValue: "Connessione assente. Continuo a riprovare.",
               comment: "Waiting screen: the phone cannot reach the server; polling goes on.")
    }

    static var waitEmailButton: String {
        String(localized: "login_approval.wait.email_button",
               defaultValue: "Ricevi un codice via email",
               comment: "Waiting screen: button that sends a recovery code by email.")
    }

    static var waitSmsButton: String {
        String(localized: "login_approval.wait.sms_button",
               defaultValue: "Ricevi un codice via SMS",
               comment: "Waiting screen: button that sends a recovery code by SMS.")
    }

    static func waitAdminHint(_ code: String) -> String {
        String(localized: "login_approval.wait.admin_hint",
               defaultValue: "Non hai più l'altro dispositivo? Chiedi all'amministratore il codice \(code)",
               comment: "Waiting screen: the person no longer has the other device. %@ is the 8-character code the administrator needs.")
    }

    static var waitCodeSentEmail: String {
        String(localized: "login_approval.wait.code_sent_email",
               defaultValue: "Ti abbiamo inviato un codice di 6 cifre via email.",
               comment: "Waiting screen: a 6-digit code was sent by email.")
    }

    static var waitCodeSentSms: String {
        String(localized: "login_approval.wait.code_sent_sms",
               defaultValue: "Ti abbiamo inviato un codice di 6 cifre via SMS.",
               comment: "Waiting screen: a 6-digit code was sent by SMS.")
    }

    static var waitCodeField: String {
        String(localized: "login_approval.wait.code_field",
               defaultValue: "Codice a 6 cifre",
               comment: "Waiting screen: placeholder of the field for the 6-digit code.")
    }

    static var waitCodeConfirm: String {
        String(localized: "login_approval.wait.code_confirm",
               defaultValue: "Conferma il codice",
               comment: "Waiting screen: button that sends the 6-digit code.")
    }

    static var waitErrorInvalidCode: String {
        String(localized: "login_approval.wait.error.invalid_code",
               defaultValue: "Codice non corretto. Riprova.",
               comment: "Waiting screen: the code is not the right one.")
    }

    static var waitErrorTooMany: String {
        String(localized: "login_approval.wait.error.too_many",
               defaultValue: "Troppi tentativi. Richiedi un nuovo codice.",
               comment: "Waiting screen: too many wrong codes.")
    }

    static var waitErrorRateLimited: String {
        String(localized: "login_approval.wait.error.rate_limited",
               defaultValue: "Troppe richieste. Riprova tra poco.",
               comment: "Waiting screen: codes are throttled.")
    }

    static var waitErrorUnavailable: String {
        String(localized: "login_approval.wait.error.unavailable",
               defaultValue: "Questo metodo non è disponibile per il tuo account.",
               comment: "Waiting screen: the recovery channel is not available for the account.")
    }

    static var waitErrorFailed: String {
        String(localized: "login_approval.wait.error.failed",
               defaultValue: "Non è stato possibile completare la richiesta. Riprova.",
               comment: "Waiting screen: a request failed.")
    }

    static var waitDeniedTitle: String {
        String(localized: "login_approval.wait.denied.title",
               defaultValue: "Accesso negato",
               comment: "Waiting screen: the request was denied, title.")
    }

    static var waitDeniedText: String {
        String(localized: "login_approval.wait.denied.text",
               defaultValue: "Un altro tuo dispositivo ha negato questa richiesta di accesso.",
               comment: "Waiting screen: the request was denied by another device of the account.")
    }

    static var waitExpiredTitle: String {
        String(localized: "login_approval.wait.expired.title",
               defaultValue: "Richiesta scaduta",
               comment: "Waiting screen: the request expired, title.")
    }

    static var waitExpiredText: String {
        String(localized: "login_approval.wait.expired.text",
               defaultValue: "Nessuno ha confermato l'accesso in tempo. Puoi riprovare ad accedere.",
               comment: "Waiting screen: nobody answered in time.")
    }

    static var waitBack: String {
        String(localized: "login_approval.wait.back",
               defaultValue: "Torna all'accesso",
               comment: "Waiting screen: button that goes back to the sign-in form.")
    }

    static func waitAccessibilityCode(_ code: String) -> String {
        String(localized: "login_approval.wait.accessibility_code",
               defaultValue: "Numero da scegliere: \(code)",
               comment: "Waiting screen: VoiceOver label of the big number. %@ is the number.")
    }

    static var sheetTitle: String {
        String(localized: "login_approval.sheet.title",
               defaultValue: "Nuovo accesso",
               comment: "Approval sheet: title.")
    }

    static var sheetIntro: String {
        String(localized: "login_approval.sheet.intro",
               defaultValue: "Un dispositivo sta cercando di accedere al tuo account. Scegli il numero che vedi sul nuovo dispositivo.",
               comment: "Approval sheet: what is asked.")
    }

    static var sheetLabelDevice: String {
        String(localized: "login_approval.sheet.label.device",
               defaultValue: "Dispositivo",
               comment: "Approval sheet: row label, name of the new device.")
    }

    static var sheetLabelPlatform: String {
        String(localized: "login_approval.sheet.label.platform",
               defaultValue: "Sistema",
               comment: "Approval sheet: row label, operating system of the new device.")
    }

    static var sheetLabelArea: String {
        String(localized: "login_approval.sheet.label.area",
               defaultValue: "Zona",
               comment: "Approval sheet: row label, country and kind of network of the request.")
    }

    static var sheetLabelTime: String {
        String(localized: "login_approval.sheet.label.time",
               defaultValue: "Ora",
               comment: "Approval sheet: row label, when the request was made.")
    }

    static var sheetWarning: String {
        String(localized: "login_approval.sheet.warning",
               defaultValue: "Se non stai cercando di accedere, nega la richiesta.",
               comment: "Approval sheet: advice when the person is not signing in.")
    }

    static var sheetDeny: String {
        String(localized: "login_approval.sheet.deny",
               defaultValue: "Nega",
               comment: "Approval sheet: button that denies the request.")
    }

    static var sheetClose: String {
        String(localized: "login_approval.sheet.close",
               defaultValue: "Chiudi",
               comment: "Approval sheet: button that closes the sheet without answering.")
    }

    static func sheetChoiceAccessibility(_ number: String) -> String {
        String(localized: "login_approval.sheet.choice_accessibility",
               defaultValue: "Numero \(number)",
               comment: "Approval sheet: VoiceOver label of a number button. %@ is the number.")
    }

    static var sheetApproved: String {
        String(localized: "login_approval.sheet.result.approved",
               defaultValue: "Accesso approvato.",
               comment: "Approval sheet: the sign-in was approved.")
    }

    static var sheetDenied: String {
        String(localized: "login_approval.sheet.result.denied",
               defaultValue: "Accesso negato.",
               comment: "Approval sheet: the sign-in was denied.")
    }

    static var sheetWrongCode: String {
        String(localized: "login_approval.sheet.result.wrong_code",
               defaultValue: "Numero sbagliato: la richiesta è stata respinta. Se il nuovo accesso è tuo, riprova ad accedere dal nuovo dispositivo.",
               comment: "Approval sheet: the chosen number was wrong, the request was closed.")
    }

    static var sheetResolved: String {
        String(localized: "login_approval.sheet.result.resolved",
               defaultValue: "Questa richiesta è già stata gestita.",
               comment: "Approval sheet: somebody else already answered.")
    }

    static var sheetFailed: String {
        String(localized: "login_approval.sheet.result.failed",
               defaultValue: "Non è stato possibile inviare la risposta. Riprova.",
               comment: "Approval sheet: the answer could not be sent.")
    }

    static var bannerTitle: String {
        String(localized: "login_approval.banner.title",
               defaultValue: "Un nuovo dispositivo chiede di accedere",
               comment: "Chat list banner: a new device waits for approval.")
    }

    static var bannerOpen: String {
        String(localized: "login_approval.banner.open",
               defaultValue: "Apri",
               comment: "Chat list banner: button that opens the approval sheet.")
    }

    static var disconnectTitle: String {
        String(localized: "login_approval.disconnect.title",
               defaultValue: "Vuoi disconnettere gli altri dispositivi?",
               comment: "Prompt after a sign-in approved on this device: title.")
    }

    static var disconnectMessage: String {
        String(localized: "login_approval.disconnect.message",
               defaultValue: "Hai appena fatto accesso da questo dispositivo. Scegli cosa fare con gli altri.",
               comment: "Prompt after a sign-in: explanation.")
    }

    static var disconnectAll: String {
        String(localized: "login_approval.disconnect.all",
               defaultValue: "Disconnetti tutti",
               comment: "Prompt after a sign-in: option that disconnects every other device.")
    }

    static var disconnectChoose: String {
        String(localized: "login_approval.disconnect.choose",
               defaultValue: "Scegli",
               comment: "Prompt after a sign-in: option that lets the person pick the devices.")
    }

    static var disconnectKeep: String {
        String(localized: "login_approval.disconnect.keep",
               defaultValue: "Mantieni",
               comment: "Prompt after a sign-in: option that keeps the other devices.")
    }

    static var disconnectContinue: String {
        String(localized: "login_approval.disconnect.continue",
               defaultValue: "Continua",
               comment: "Prompt after a sign-in: button that applies the chosen option.")
    }

    static var disconnectListFailed: String {
        String(localized: "login_approval.disconnect.list_failed",
               defaultValue: "Non è stato possibile leggere l'elenco dei dispositivi. Puoi riprovare, mantenerli o disconnettere tutti.",
               comment: "Prompt after a sign-in: the list of devices could not be read.")
    }

    static var disconnectPickTitle: String {
        String(localized: "login_approval.disconnect.pick.title",
               defaultValue: "Scegli i dispositivi da disconnettere",
               comment: "Device picker: title.")
    }

    static var disconnectPickConfirm: String {
        String(localized: "login_approval.disconnect.pick.confirm",
               defaultValue: "Disconnetti selezionati",
               comment: "Device picker: button that disconnects the checked devices.")
    }

    static var disconnectPickBack: String {
        String(localized: "login_approval.disconnect.pick.back",
               defaultValue: "Indietro",
               comment: "Device picker: back to the question.")
    }

    static var disconnectPickNone: String {
        String(localized: "login_approval.disconnect.pick.none",
               defaultValue: "Non ci sono altri dispositivi.",
               comment: "Device picker: the account has only this device.")
    }

    static var disconnectPickFailed: String {
        String(localized: "login_approval.disconnect.pick.failed",
               defaultValue: "Alcuni dispositivi non sono stati disconnessi. Riprova.",
               comment: "Device picker: at least one disconnect failed.")
    }

    static var disconnectPickCurrent: String {
        String(localized: "login_approval.disconnect.pick.current",
               defaultValue: "Questo dispositivo",
               comment: "Device picker: the row of the current device, not selectable.")
    }

    static var waitErrorCodeExpired: String {
        String(localized: "login_approval.wait.error.code_expired",
               defaultValue: "Codice scaduto. Richiedi un nuovo codice.",
               comment: "Waiting screen: the recovery code expired or is gone.")
    }

    static var waitRevokedTitle: String {
        String(localized: "login_approval.wait.revoked.title",
               defaultValue: "Accesso non completato",
               comment: "Waiting screen: the sessions were revoked after the approval, title.")
    }

    static var waitRevokedText: String {
        String(localized: "login_approval.wait.revoked.text",
               defaultValue: "Le sessioni dell'account sono state chiuse subito dopo l'approvazione. Accedi di nuovo.",
               comment: "Waiting screen: the sessions were revoked after the approval.")
    }

    static var disconnectFailed: String {
        String(localized: "login_approval.disconnect.failed",
               defaultValue: "Non è stato possibile disconnettere gli altri dispositivi. Riprova.",
               comment: "Prompt after a sign-in: the other devices could not be disconnected.")
    }

    static var disconnectDone: String {
        String(localized: "login_approval.disconnect.done",
               defaultValue: "Gli altri dispositivi sono stati disconnessi.",
               comment: "Message after the other devices were disconnected.")
    }

    static var noticeTitle: String {
        String(localized: "account_notice.sheet.title",
               defaultValue: "Avviso sull'account",
               comment: "Alert title for a notice about the account.")
    }

    static var noticeOk: String {
        String(localized: "account_notice.sheet.ok",
               defaultValue: "OK",
               comment: "Alert button that closes a notice.")
    }

    static var noticeLoginDenied: String {
        String(localized: "account_notice.login_denied",
               defaultValue: "Una richiesta di accesso al tuo account è stata negata.",
               comment: "Notice: a sign-in request on the account was denied.")
    }

    static var noticeLoginExpired: String {
        String(localized: "account_notice.login_expired",
               defaultValue: "Una richiesta di accesso al tuo account è scaduta senza risposta.",
               comment: "Notice: a sign-in request on the account expired.")
    }

    static var noticeLoginRecovered: String {
        String(localized: "account_notice.login_recovered",
               defaultValue: "Un nuovo dispositivo è stato approvato con un codice inviato via email o SMS, oppure dall'amministratore. Se non sei stato tu, contatta l'amministratore.",
               comment: "Notice: a new device was approved with a code sent by email or SMS, or by the administrator.")
    }

    static var noticeDeviceDisconnected: String {
        String(localized: "account_notice.device_disconnected",
               defaultValue: "Questo dispositivo è stato disconnesso da un tuo nuovo accesso. Se non sei stato tu, contatta l'amministratore.",
               comment: "Notice: this device was disconnected by a new sign-in.")
    }

    static var noticeOpenDevices: String {
        String(localized: "account_notice.open_devices",
               defaultValue: "Vedi i dispositivi",
               comment: "Alert button of the notice about a changed recovery contact: opens the list of the account's devices.")
    }

    static var noticeRecoveryContactChanged: String {
        String(localized: "account_notice.recovery_contact_changed",
               defaultValue: "L'email o il numero per il recupero del tuo account sono stati modificati. Se non sei stato tu, contatta l'amministratore.",
               comment: "Notice: the recovery email or phone changed.")
    }

    static var noticePhoneMovedTitle: String {
        String(localized: "account_notice.phone_moved.title",
               defaultValue: "Numero di telefono spostato",
               comment: "Alert title: the phone number of the account was linked to another account.")
    }

    static var noticePhoneMoved: String {
        String(localized: "account_notice.phone_moved.body",
               defaultValue: "Il tuo numero è stato collegato a un altro account. Se non sei stato tu, contatta l'assistenza.",
               comment: "Alert text: the phone number of the account was linked to another account.")
    }

    static var rcTitle: String {
        String(localized: "settings.recovery_contacts.title",
               defaultValue: "Email e numero per il recupero",
               comment: "Settings row and screen title: optional email and phone number used to recover access.")
    }

    static var rcExplain: String {
        String(localized: "settings.recovery_contacts.subtitle",
               defaultValue: "Servono solo se perdi il telefono",
               comment: "Settings row subtitle and one-line explanation of the recovery contacts.")
    }

    static var rcEmail: String {
        String(localized: "settings.recovery_contacts.email",
               defaultValue: "Email",
               comment: "Recovery contacts screen: section title of the email.")
    }

    static var rcPhone: String {
        String(localized: "settings.recovery_contacts.phone",
               defaultValue: "Numero di telefono",
               comment: "Recovery contacts screen: section title of the phone number.")
    }

    static var rcNotSet: String {
        String(localized: "settings.recovery_contacts.not_set",
               defaultValue: "Non impostato",
               comment: "Recovery contacts screen: nothing is set for this contact.")
    }

    static var rcVerified: String {
        String(localized: "settings.recovery_contacts.verified",
               defaultValue: "Verificato",
               comment: "Recovery contacts screen: the contact is verified.")
    }

    static var rcUnverified: String {
        String(localized: "settings.recovery_contacts.unverified",
               defaultValue: "Da verificare",
               comment: "Recovery contacts screen: the contact is not verified yet.")
    }

    static var rcAdd: String {
        String(localized: "settings.recovery_contacts.add",
               defaultValue: "Aggiungi",
               comment: "Recovery contacts screen: button that adds a contact.")
    }

    static var rcChange: String {
        String(localized: "settings.recovery_contacts.change",
               defaultValue: "Cambia",
               comment: "Recovery contacts screen: button that replaces a contact.")
    }

    static var rcRemove: String {
        String(localized: "settings.recovery_contacts.remove",
               defaultValue: "Rimuovi",
               comment: "Recovery contacts screen: button that removes a contact.")
    }

    static var rcRemoveConfirm: String {
        String(localized: "settings.recovery_contacts.remove_confirm",
               defaultValue: "Rimuovere questo contatto di recupero?",
               comment: "Recovery contacts screen: confirmation question before removing a contact.")
    }

    static var rcSendCode: String {
        String(localized: "settings.recovery_contacts.send_code",
               defaultValue: "Invia codice",
               comment: "Recovery contacts screen: button that sends the verification code.")
    }

    static var rcVerify: String {
        String(localized: "settings.recovery_contacts.verify",
               defaultValue: "Verifica",
               comment: "Recovery contacts screen: button that checks the verification code.")
    }

    static var rcCancel: String {
        String(localized: "settings.recovery_contacts.cancel",
               defaultValue: "Annulla",
               comment: "Recovery contacts screen: button that leaves the code step.")
    }

    static var rcCodeSent: String {
        String(localized: "settings.recovery_contacts.code_sent",
               defaultValue: "Ti abbiamo inviato un codice di 6 cifre. Inseriscilo qui sotto.",
               comment: "Recovery contacts screen: a verification code was sent.")
    }

    static var rcCodePlaceholder: String {
        String(localized: "settings.recovery_contacts.code_placeholder",
               defaultValue: "Codice a 6 cifre",
               comment: "Recovery contacts screen: placeholder of the code field.")
    }

    static var rcEmailPlaceholder: String {
        String(localized: "settings.recovery_contacts.email_placeholder",
               defaultValue: "nome@esempio.it",
               comment: "Recovery contacts screen: placeholder of the email field.")
    }

    static var rcPhonePlaceholder: String {
        String(localized: "settings.recovery_contacts.phone_placeholder",
               defaultValue: "+39 333 1234567",
               comment: "Recovery contacts screen: placeholder of the phone field (international format).")
    }

    static var rcErrorInvalidValue: String {
        String(localized: "settings.recovery_contacts.error.invalid_value",
               defaultValue: "Valore non valido. Controlla e riprova.",
               comment: "Recovery contacts screen: the email or number is not valid.")
    }

    static var rcErrorInvalidCode: String {
        String(localized: "settings.recovery_contacts.error.invalid_code",
               defaultValue: "Codice non corretto. Riprova.",
               comment: "Recovery contacts screen: the verification code is wrong.")
    }

    static var rcErrorRateLimited: String {
        String(localized: "settings.recovery_contacts.error.rate_limited",
               defaultValue: "Troppe richieste. Riprova tra poco.",
               comment: "Recovery contacts screen: too many requests.")
    }

    static var rcErrorClock: String {
        String(localized: "settings.recovery_contacts.error.clock",
               defaultValue: "L'orario di questo dispositivo non è corretto. Imposta data e ora in automatico e riprova.",
               comment: "Recovery contacts screen: the device clock is wrong, the server refused the signed time.")
    }

    static var rcErrorFailed: String {
        String(localized: "settings.recovery_contacts.error.failed",
               defaultValue: "Non è stato possibile completare l'operazione. Riprova.",
               comment: "Recovery contacts screen: a request failed.")
    }

    static var rcLoadFailed: String {
        String(localized: "settings.recovery_contacts.load_failed",
               defaultValue: "Non è stato possibile leggere le impostazioni di recupero.",
               comment: "Recovery contacts screen: the current state could not be read.")
    }
}
