import AppIntents
import Foundation

/// "Nuovo messaggio": opens the app on the new-conversation sheet, where the contact is picked. It sends nothing and takes no
/// parameter. The session and the app lock are honoured when the chat list takes the request (`QuickActionPolicy.take`), as for
/// the Home Screen quick action of the same name.
struct NewMessageIntent: AppIntent {
    static var title: LocalizedStringResource = "Nuovo messaggio"
    static var description = IntentDescription("Apre Q-Audion sulla scelta del contatto a cui scrivere.")

    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        QuickActions.handle(type: QuickActionKind.newMessage.rawValue)
        return .result()
    }
}
