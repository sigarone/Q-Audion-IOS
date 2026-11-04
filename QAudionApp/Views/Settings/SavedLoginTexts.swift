import Foundation

/// Texts of the "keep the password behind Face ID / Touch ID" question and of the sign-in button that uses it.
/// `method` is the system's own name for the biometry ("Face ID", "Touch ID"), which is not translated.
enum SavedLoginTexts {
    static func promptTitle(_ method: String) -> String {
        String(localized: "saved_login.prompt.title",
               defaultValue: "Salvare la password con \(method)?",
               comment: "Question after a sign-in or a password change: keep the password behind biometrics. %@ is Face ID or Touch ID.")
    }

    static func promptMessage(_ method: String) -> String {
        String(localized: "saved_login.prompt.message",
               defaultValue: "La password resta su questo dispositivo, protetta da \(method). La prossima volta potrai accedere senza digitarla.",
               comment: "Explanation under the question about keeping the password behind biometrics. %@ is Face ID or Touch ID.")
    }

    static var promptSave: String {
        String(localized: "saved_login.prompt.save",
               defaultValue: "Salva",
               comment: "Button: keep the password behind biometrics.")
    }

    static var promptDecline: String {
        String(localized: "saved_login.prompt.decline",
               defaultValue: "Non salvare",
               comment: "Button: do not keep the password.")
    }

    static func signInButton(_ method: String) -> String {
        String(localized: "saved_login.signin",
               defaultValue: "Accedi con \(method)",
               comment: "Button on the extension sign-in screen: sign in with the saved password after a biometric check. %@ is Face ID or Touch ID.")
    }

    static var unlockReason: String {
        String(localized: "saved_login.reason",
               defaultValue: "Accedi a Q-Audion con la password salvata",
               comment: "Reason shown in the system biometric prompt that unlocks the saved password.")
    }

    static var readFailed: String {
        String(localized: "saved_login.read_failed",
               defaultValue: "Non riesco a usare la password salvata. Inseriscila a mano.",
               comment: "Extension sign-in screen: the saved password could not be read (cancelled, or the biometrics changed).")
    }

    static var savedRejected: String {
        String(localized: "saved_login.rejected",
               defaultValue: "La password salvata non è più valida, inseriscila di nuovo.",
               comment: "Extension sign-in screen: the server refused the saved password (it was changed elsewhere); the saved copy was removed.")
    }

    static func settingsTitle(_ method: String) -> String {
        String(localized: "saved_login.settings.title",
               defaultValue: "Password salvata con \(method)",
               comment: "Settings switch: keep the password behind biometrics. %@ is Face ID or Touch ID.")
    }

    static var settingsStored: String {
        String(localized: "saved_login.settings.stored",
               defaultValue: "Usata per accedere senza digitarla",
               comment: "Settings switch subtitle: a password is saved and will be used to sign in.")
    }

    static var settingsPending: String {
        String(localized: "saved_login.settings.pending",
               defaultValue: "Te lo chiederò al prossimo accesso o cambio password",
               comment: "Settings switch subtitle: nothing saved yet, the question comes at the next sign-in or password change.")
    }

    static var settingsOff: String {
        String(localized: "saved_login.settings.off",
               defaultValue: "Non salvata",
               comment: "Settings switch subtitle: the password is not saved.")
    }
}
