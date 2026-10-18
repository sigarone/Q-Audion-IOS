import Foundation

/// The choice of Settings > Trasporto as one comparable value: the mode and the custom TURN server (address, user name and
/// password).
///
/// The screen keeps three of them: what is typed (the draft), what the calls use (read back from `TransportPreferences`)
/// and what the last check ran with. Two notes depend on how they compare, "Salvato. Vale dalla prossima chiamata 1 a 1."
/// and "Il controllo è stato fatto con una modalità o un indirizzo non ancora salvati". Their conditions used to sit in
/// the SwiftUI container, which needs `AppState` and cannot be built in a test, so nothing fixed WHEN a note appears. They
/// live here, as pure code, and `TransportChoiceTests` pins each one, including the round trip through the real storage
/// and the refusal of an address that cannot be saved.
public struct TransportChoice: Equatable, Sendable {

    /// What the three fields of the custom server hold (the address, the user name, the password).
    public enum AddressState: Equatable, Sendable {
        case empty
        /// A TURN address (`turn:host:port`) with its user name and password.
        case valid
        /// A well formed `turn:`/`turns:` address with no user name or no password. It is never saved, never checked and
        /// never handed to libwebrtc (which would reject the whole configuration for it); the note under the field says
        /// what to add.
        case needsCredentials
        /// Not a TURN address at all, one that cannot be read, or one with credentials written inside it (they belong to
        /// the user name and password fields).
        case invalid

        /// "Salva" and the check refuse the address in these states.
        public var blocksSaving: Bool { self == .invalid || self == .needsCredentials }
    }

    public let mode: TransportSettingsViewModel.Mode
    public let addressState: AddressState
    /// The server as the calls would use it, in the one-text form `turn:user:password@host:port` with the credentials in
    /// it (`TransportCustomTurn.make`); `nil` when the fields are empty or do not make a usable server. It holds the
    /// password: it lives in memory only, never log it.
    public let customTurnUrl: URL?

    /// What is typed on the screen: the mode of the picker, the address field (`turn:host:port`, no credentials in it), the
    /// user name field and the password field.
    public init(mode: TransportSettingsViewModel.Mode, address: String, username: String, password: String) {
        let evaluated = Self.evaluate(address: address, username: username, password: password)
        self.mode = mode
        self.addressState = evaluated.state
        self.customTurnUrl = evaluated.url
    }

    private static func evaluate(address: String, username: String,
                                 password: String) -> (state: AddressState, url: URL?) {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return (.empty, nil) }
        // The credentials have their own fields: an address with an `@` inside is refused, so a password typed into the
        // address field is not kept as a readable text there.
        guard let parsed = TransportCustomTurn.parseAddress(trimmed), !parsed.hasCredentialsInside else {
            return (.invalid, nil)
        }
        if username.isEmpty || password.isEmpty { return (.needsCredentials, nil) }
        guard let server = TransportCustomTurn.make(address: trimmed, username: username, password: password) else {
            return (.invalid, nil)
        }
        return (.valid, server.storedURL)
    }

    /// What the calls use now: the mode and the server as they are in the storage.
    public init(preferences: TransportPreferences) {
        let url: URL? = preferences.customTurnUrl
        self.mode = preferences.mode
        self.customTurnUrl = url
        self.addressState = url == nil ? .empty : .valid
    }

    private var server: TransportCustomTurn? {
        customTurnUrl.flatMap { TransportCustomTurn.parse($0.absoluteString).server }
    }

    /// The text of the address field for this choice: `turn:host:port`, no credentials; empty when there is no server.
    public var addressField: String { server?.iceUrl ?? "" }
    /// The text of the user name field for this choice; empty when there is no server.
    public var usernameField: String { server?.username ?? "" }
    /// The text of the password field for this choice; empty when there is no server.
    public var passwordField: String { server?.credential ?? "" }

    /// The server in the one-text form, credentials included, for comparing two choices; empty when there is none. It holds
    /// the password: not for showing or logging.
    public var addressWithCredentials: String { customTurnUrl?.absoluteString ?? "" }

    /// Same mode and same server once normalised (case of the scheme, surrounding spaces). Whether the typed text was
    /// usable is not compared (an address that cannot be used counts as no address).
    public func hasSameValues(as other: TransportChoice) -> Bool {
        mode == other.mode && addressWithCredentials == other.addressWithCredentials
    }

    /// What is on the screen is exactly what is stored: the typed address is usable (an unusable one, or one without
    /// credentials, is never saved) and the mode and the normalised address are the stored ones.
    public func isSaved(as stored: TransportChoice) -> Bool {
        !addressState.blocksSaving && hasSameValues(as: stored)
    }
}

/// What the screen knows about saving and checking, and the two notes that follow from it.
///
/// - `saved` is what the calls use. It is set when the screen opens and again after every "Salva", from the storage read
///   back after the write (`recordSave(readBack:)`), not from the draft: if the write did not take, the note does not claim
///   it did.
/// - `checked` is what the last check ran with (`recordCheck(_:)`).
public struct TransportSaveState: Equatable, Sendable {

    public private(set) var saved: TransportChoice
    public private(set) var checked: TransportChoice?
    public private(set) var justSaved: Bool

    public init(saved: TransportChoice) {
        self.saved = saved
        self.checked = nil
        self.justSaved = false
    }

    /// A check was started with `choice` (the draft at that moment).
    public mutating func recordCheck(_ choice: TransportChoice) {
        checked = choice
    }

    /// "Salva" was pressed and the storage was written. `readBack` is the storage read again.
    public mutating func recordSave(readBack: TransportChoice) {
        saved = readBack
        justSaved = true
    }

    /// "Salva": `write` stores the draft, then the storage is read again (`readBack`) and recorded. A draft whose address
    /// cannot be saved (`AddressState.blocksSaving`: not a TURN address, or one without user name and password) is refused:
    /// nothing is written, nothing is recorded, the stored values stay as they were and the "Salvato" note does not
    /// appear. Returns whether the draft was saved. This is where the refusal lives, so a test can drive it without the
    /// screen.
    @discardableResult
    public mutating func save(draft: TransportChoice,
                              write: (TransportChoice) -> Void,
                              readBack: () -> TransportChoice) -> Bool {
        guard !draft.addressState.blocksSaving else { return false }
        write(draft)
        recordSave(readBack: readBack())
        return true
    }

    /// "Salvato. Vale dalla prossima chiamata 1 a 1.": only after a save, and only while the screen still shows exactly what the
    /// storage holds. Changing the mode or the address hides it; putting the same values back shows it again, because it is
    /// true again.
    public func showsSavedNote(draft: TransportChoice) -> Bool {
        justSaved && draft.isSaved(as: saved)
    }

    /// The last check ran with the mode and address that are stored. The screen shows "Il controllo è stato fatto con una
    /// modalità o un indirizzo non ancora salvati" under a check result when this is `false`: the mode alone, the address
    /// alone or both can differ, and the text names both. `true` when no check ran yet: there is no result to warn about.
    public var checkMatchesSaved: Bool {
        checked?.hasSameValues(as: saved) ?? true
    }
}
