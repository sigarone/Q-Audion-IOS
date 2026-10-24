import AppIntents
import Foundation

/// "Condividi posizione": the App Intent behind Siri, Shortcuts and the Action button (iOS has no system intent for location).
///
/// Running it opens the app on the chat with the chosen contact and presents the share sheet that is already there, where the user
/// confirms with a tap: nothing is sent by voice alone. The remote switch, the session and the app lock are honoured by
/// `LocationShareIntentRouter`; the location permission is asked by the sheet, When In Use only.
///
/// The contact is an `AppEntity` made of the account id and the display name, listed by a query that applies the same filters as
/// the app (no blocked contact, nothing while signed out or locked). Phrases: `QAudionAppShortcuts` below, translated in
/// `<lang>.lproj/AppShortcuts.strings`. The strings of titles and parameters are in `Localizable.xcstrings`.

// MARK: - Mode

/// One-off position, or a live share with one of the durations of the share sheet.
enum LocationShareModeOption: String, AppEnum {
    case instant
    case live15m
    case live1h
    case live8h
    case live24h

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Modalità"

    static var caseDisplayRepresentations: [LocationShareModeOption: DisplayRepresentation] = [
        .instant: "Posizione attuale",
        .live15m: "In tempo reale, 15 minuti",
        .live1h: "In tempo reale, 1 ora",
        .live8h: "In tempo reale, 8 ore",
        .live24h: "In tempo reale, 24 ore"
    ]

    var requestMode: LocationShareRequestMode {
        switch self {
        case .instant: return .instant
        case .live15m: return .live(seconds: 900)
        case .live1h: return .live(seconds: 3_600)
        case .live8h: return .live(seconds: 28_800)
        case .live24h: return .live(seconds: 86_400)
        }
    }
}

// MARK: - Contact

/// A contact of the app as Siri and Shortcuts see it: the account id and the name, nothing else.
struct LocationShareContactEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Contatto"
    static var defaultQuery = LocationShareContactQuery()

    var id: String
    var displayName: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(displayName)")
    }

    init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }

    init(_ facts: LocationShareContactFacts) {
        self.init(id: facts.userId, displayName: facts.displayName)
    }
}

struct LocationShareContactQuery: EntityStringQuery {

    func entities(for identifiers: [String]) async throws -> [LocationShareContactEntity] {
        await MainActor.run {
            LocationShareIntentPolicy.resolving(LocationShareIntentRouter.resolvableContacts(), ids: identifiers)
                .map(LocationShareContactEntity.init)
        }
    }

    func entities(matching string: String) async throws -> [LocationShareContactEntity] {
        await MainActor.run {
            LocationShareIntentPolicy.matching(LocationShareIntentRouter.listableContacts(), query: string)
                .map(LocationShareContactEntity.init)
        }
    }

    func suggestedEntities() async throws -> [LocationShareContactEntity] {
        await MainActor.run {
            LocationShareIntentRouter.listableContacts().map(LocationShareContactEntity.init)
        }
    }
}

// MARK: - Intent

struct ShareLocationIntent: AppIntent {
    static var title: LocalizedStringResource = "Condividi posizione"
    static var description = IntentDescription(
        "Apre la chat con un contatto e mostra la conferma per condividere la posizione. Non invia nulla finché non confermi con un tocco.")

    /// The share sheet is on the screen of the app.
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Contatto", requestValueDialog: "Con chi vuoi condividere la posizione?")
    var contact: LocationShareContactEntity

    @Parameter(title: "Modalità", default: .instant)
    var mode: LocationShareModeOption

    static var parameterSummary: some ParameterSummary {
        Summary("Condividi la posizione con \(\.$contact)") {
            \.$mode
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = LocationShareIntentRouter.handle(contactId: contact.id, mode: mode.requestMode)
        let sentence: String = LocationShareIntentStrings.dialog(for: outcome)
        return .result(dialog: "\(sentence)")
    }
}

// MARK: - Shortcuts

/// The phrases are written in Italian, the development language; `<lang>.lproj/AppShortcuts.strings` has them in en, fr, de, es and pt-BR.
/// Every phrase names the app, as the framework requires.
struct QAudionAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ShareLocationIntent(),
            phrases: [
                "Condividi la posizione con \(\.$contact) su \(.applicationName)",
                "Manda la mia posizione a \(\.$contact) su \(.applicationName)",
                "Condividi la mia posizione su \(.applicationName)"
            ],
            shortTitle: "Condividi posizione",
            systemImageName: "location.fill"
        )
    }
}
