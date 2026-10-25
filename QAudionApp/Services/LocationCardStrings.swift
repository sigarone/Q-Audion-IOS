import Foundation

/// The texts of the location card, of the share sheet and of the strip. Each is a lookup in `Localizable.xcstrings` (it, en, es, fr, de,
/// pt-BR); the ones with a value take it as an already formatted string, so every placeholder is `%@`. None of them ever carries a
/// position: a value here is a duration, a clock time or a radius in metres.
enum LocationCardStrings {

    // MARK: Card

    static var pinTitle: String {
        String(localized: "location.card.pin_title", defaultValue: "Posizione", comment: "Title of the card of a shared position.")
    }

    static var liveTitle: String {
        String(localized: "location.card.live_title", defaultValue: "Posizione in tempo reale", comment: "Title of the card of a live location share.")
    }

    static var open: String {
        String(localized: "location.card.open", defaultValue: "Apri", comment: "Button of a location card that opens the position in a map application.")
    }

    static var openInMaps: String {
        String(localized: "location.card.open_maps", defaultValue: "Apri in Mappe", comment: "Action of a location card: open the position in Apple Maps.")
    }

    static var openInGoogleMaps: String {
        String(localized: "location.card.open_google_maps", defaultValue: "Apri in Google Maps", comment: "Action of a location card: open the position in Google Maps (the app when it is installed, a web page otherwise).")
    }

    static var shareGpx: String {
        String(localized: "location.card.share_gpx", defaultValue: "Condividi GPX", comment: "Action of a location card: share the position as a GPX file.")
    }

    static var copyCoordinates: String {
        String(localized: "location.card.copy_coordinates", defaultValue: "Copia coordinate", comment: "Action of a location card: copy the coordinates.")
    }

    static var stop: String {
        String(localized: "location.card.stop", defaultValue: "Interrompi", comment: "Button that stops a live location share you started.")
    }

    static var ended: String {
        String(localized: "location.card.ended", defaultValue: "Condivisione terminata", comment: "State of a live location share that is over: no position is shown any more.")
    }

    static var unreadable: String {
        String(localized: "location.card.unreadable", defaultValue: "Impossibile mostrare la posizione.", comment: "Shown instead of a location message that cannot be displayed.")
    }

    static var approximate: String {
        String(localized: "location.card.approximate", defaultValue: "Posizione approssimativa", comment: "Said of a shared position when the sender only allowed approximate location.")
    }

    static func accuracy(metres: Int) -> String {
        let value: String = String(describing: metres)
        return String(localized: "location.card.accuracy", defaultValue: "±\(value) m", comment: "Accuracy radius of a shared position in metres; %@ is the number.")
    }

    static func accessibilityAccuracy(metres: Int) -> String {
        let value: String = String(describing: metres)
        return String(localized: "location.card.a11y_accuracy", defaultValue: "precisione \(value) metri", comment: "VoiceOver text of the accuracy of a shared position; %@ is the number of metres.")
    }

    static func until(_ clock: String) -> String {
        String(localized: "location.card.until", defaultValue: "fino alle \(clock)", comment: "A live share runs until a time of day; %@ is the time.")
    }

    static func updated(ago: String) -> String {
        String(localized: "location.card.updated", defaultValue: "aggiornata \(ago) fa", comment: "How long ago a live share was last updated; %@ is a short duration such as 20 s or 3 min.")
    }

    static func lastUpdate(ago: String) -> String {
        String(localized: "location.card.last_update", defaultValue: "Ultimo aggiornamento \(ago) fa", comment: "A live share has not been updated for a while; %@ is a short duration such as 3 min.")
    }

    // MARK: Share sheet

    static var sheetTitle: String {
        String(localized: "location.sheet.title", defaultValue: "Condividi posizione", comment: "Title of the sheet where you choose to send your position or share it live.")
    }

    static var sheetSendCurrent: String {
        String(localized: "location.sheet.send_current", defaultValue: "Invia la posizione attuale", comment: "Button that sends the current position as a message.")
    }

    static func sheetAccuracy(metres: Int) -> String {
        let value: String = String(describing: metres)
        return String(localized: "location.sheet.accuracy", defaultValue: "Precisione ±\(value) m", comment: "Live accuracy of the current position in the share sheet; %@ is the number of metres.")
    }

    static var sheetApproximate: String {
        String(localized: "location.sheet.approximate", defaultValue: "Posizione approssimativa", comment: "The share sheet says the system only gives an approximate position.")
    }

    static var sheetFullAccuracy: String {
        String(localized: "location.sheet.full_accuracy", defaultValue: "Richiedi la precisione massima", comment: "Button that asks the system once for the exact position.")
    }

    static var sheetShareLive: String {
        String(localized: "location.sheet.share_live", defaultValue: "Condividi la posizione in tempo reale", comment: "Section of the share sheet that starts a live location share.")
    }

    static var sheetPreset15m: String {
        String(localized: "location.sheet.preset_15m", defaultValue: "15 minuti", comment: "Duration of a live location share.")
    }

    static var sheetPreset1h: String {
        String(localized: "location.sheet.preset_1h", defaultValue: "1 ora", comment: "Duration of a live location share.")
    }

    static var sheetPreset8h: String {
        String(localized: "location.sheet.preset_8h", defaultValue: "8 ore", comment: "Duration of a live location share.")
    }

    static var sheetPreset24h: String {
        String(localized: "location.sheet.preset_24h", defaultValue: "24 ore", comment: "Duration of a live location share.")
    }

    static var sheetGroupPinOnly: String {
        String(localized: "location.sheet.group_pin_only", defaultValue: "In un gruppo puoi inviare la posizione attuale. La condivisione in tempo reale è disponibile solo nelle chat singole.", comment: "Shown in the share sheet of a group chat.")
    }

    static func explainer(name: String) -> String {
        String(localized: "location.sheet.explainer", defaultValue: "La posizione è cifrata end-to-end: la vede solo \(name), non il server. Puoi interrompere quando vuoi e si ferma da sola alla scadenza.", comment: "Explanation shown before the first live location share; %@ is the name of the contact.")
    }

    static var explainerContinue: String {
        String(localized: "location.sheet.explainer_continue", defaultValue: "Continua", comment: "Button of the explanation shown before the first live share: when the location permission is not decided yet it leads to the system request; otherwise it confirms and starts the live share.")
    }

    static var cancel: String {
        String(localized: "location.sheet.cancel", defaultValue: "Annulla", comment: "Button that closes the location sheet without sending.")
    }

    static var gettingFix: String {
        String(localized: "location.sheet.getting_fix", defaultValue: "Sto ottenendo la posizione…", comment: "Shown while the phone is getting a position.")
    }

    static var permissionDenied: String {
        String(localized: "location.sheet.permission_denied", defaultValue: "L'accesso alla posizione è disattivato. Puoi attivarlo in Impostazioni > Privacy e sicurezza > Localizzazione > Q-Audion.", comment: "Shown when the location permission is off, with the path to turn it on.")
    }

    static var openSettings: String {
        String(localized: "location.sheet.open_settings", defaultValue: "Apri Impostazioni", comment: "Button that opens the system settings of the app.")
    }

    static var fixUnavailable: String {
        String(localized: "location.sheet.fix_unavailable", defaultValue: "Impossibile ottenere la posizione. Riprova tra poco.", comment: "Shown when the phone could not get a position.")
    }

    static var fixTooOld: String {
        String(localized: "location.sheet.fix_too_old", defaultValue: "La posizione non è abbastanza recente. Riprova.", comment: "Shown when the position the phone has is too old to send.")
    }

    static var sendFailed: String {
        String(localized: "location.sheet.send_failed", defaultValue: "Non è stato possibile inviare la posizione.", comment: "Shown when the position could not be sent.")
    }

    static var notAvailable: String {
        String(localized: "location.sheet.not_available", defaultValue: "La condivisione della posizione non è disponibile ora.", comment: "Shown when location sharing is switched off.")
    }

    static var attachAccessibility: String {
        String(localized: "location.attach.accessibility", defaultValue: "Condividi posizione", comment: "VoiceOver label of the button in the chat composer that opens the location sheet.")
    }

    // MARK: Strip, chip, settings

    static func stripText(until clock: String) -> String {
        String(localized: "location.strip.text", defaultValue: "Stai condividendo la posizione fino alle \(clock)", comment: "Strip above the composer while you share your position live; %@ is the time it ends.")
    }

    static var chipLive: String {
        String(localized: "location.chip.live", defaultValue: "Live", comment: "Small tag on a conversation in the list while you share your position there.")
    }

    static var settingsTitle: String {
        String(localized: "location.settings.title", defaultValue: "Posizione condivisa", comment: "Section of the privacy settings that lists the live location shares you are running.")
    }

    static var settingsNone: String {
        String(localized: "location.settings.none", defaultValue: "Nessuna condivisione attiva.", comment: "Shown when you are not sharing your position with anyone.")
    }

    static var settingsStopAll: String {
        String(localized: "location.settings.stop_all", defaultValue: "Interrompi tutte", comment: "Button that stops every live location share you are running.")
    }

    static func settingsRow(name: String, clock: String) -> String {
        String(localized: "location.settings.row", defaultValue: "\(name), fino alle \(clock)", comment: "A running live share in the settings list; the first %@ is the contact, the second the time it ends.")
    }

    static var interruptedTitle: String {
        String(localized: "location.interrupted.title", defaultValue: "Condivisione interrotta", comment: "Title of the alert shown when a live location share was ended because the app had been closed.")
    }

    static var interruptedBody: String {
        String(localized: "location.interrupted.body", defaultValue: "La condivisione della posizione in tempo reale è stata interrotta perché l'app era stata chiusa. Puoi avviarla di nuovo dalla chat.", comment: "Body of the alert shown when a live location share was ended because the app had been closed.")
    }

    static var interruptedOk: String {
        String(localized: "location.interrupted.ok", defaultValue: "OK", comment: "Button that closes the alert.")
    }

    static var startNotice: String {
        String(localized: "location.notice.start_failed", defaultValue: "Non è stato possibile avviare la condivisione della posizione.", comment: "Shown when a live location share could not be started.")
    }

    static var forwardRefused: String {
        String(localized: "location.notice.forward_refused", defaultValue: "Le posizioni non si possono inoltrare.", comment: "Shown when the user tries to forward a shared position.")
    }
}

/// Clock times and short durations of the location card, in the language the app shows.
enum LocationCardFormat {

    private static func locale() -> Locale {
        Locale(identifier: AppLanguageManager.effectiveLanguageCode)
    }

    /// `14:32` in the language of the app.
    static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }

    static func clock(_ unix: Int64?) -> String {
        guard let unix else { return "" }
        return clock(Date(timeIntervalSince1970: Double(unix)))
    }

    /// `20 s`, `3 min`, `2 h`: the time between `unix` and `now`, one unit, abbreviated in the language of the app.
    static func elapsed(since unix: Int64?, now: Date) -> String {
        guard let unix else { return "" }
        let seconds: Double = max(0, now.timeIntervalSince1970 - Double(unix))
        let formatter = DateComponentsFormatter()
        var calendar = Calendar.current
        calendar.locale = locale()
        formatter.calendar = calendar
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.maximumUnitCount = 1
        formatter.zeroFormattingBehavior = .dropAll
        let rounded: Double = seconds < 1 ? 1 : seconds.rounded(.down)
        return formatter.string(from: rounded) ?? ""
    }
}
