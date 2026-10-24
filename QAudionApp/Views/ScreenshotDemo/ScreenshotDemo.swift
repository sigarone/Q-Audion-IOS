#if SCREENSHOT_DEMO
import SwiftUI
import UIKit
import QAudionEngine

// Demo scenes for the store screenshot workflow (.github/workflows/ios-store-screenshots.yml).
//
// This whole file is compiled only when the build is given `-DSCREENSHOT_DEMO` (the workflow passes it through
// OTHER_SWIFT_FLAGS). No project spec sets it, so TestFlight and store builds never contain any of it. It is
// active only when the app is launched with `-qaDemoScene <name>`; it uses neutral made-up data, no account and no
// network.
//
// Scenes: chatlist, chat, location, settings, privacy (the real screens inside the real tab shell, over a locally seeded
// store) and call, call-sas (the in-call screen fed with fixed values).

enum ScreenshotDemoRoute: Hashable {
    case privacy
}

@MainActor
enum ScreenshotDemo {

    static var scene: String { UserDefaults.standard.string(forKey: "qaDemoScene") ?? "" }
    static var isActive: Bool { !scene.isEmpty }
    static var isCallScene: Bool { scene == "call" || scene == "call-sas" }
    static var opensPrivacy: Bool { scene == "privacy" }
    /// Set by the chat screen when it appears; stops the retries that open it.
    static var chatOpened = false
    /// Points the largest scroll view is moved down after the screen appears (0 = untouched).
    static var scrollOffset: CGFloat { CGFloat(UserDefaults.standard.double(forKey: "qaDemoScroll")) }

    static var initialTab: HomeView.Tab {
        switch scene {
        case "settings", "privacy": return .settings
        default: return .chats
        }
    }

    /// Before anything else reads the defaults: the one-time mesh question must not cover the screens.
    static func seedEarly() {
        guard isActive else { return }
        MeshConsentStore().record(.declined)
    }

    /// A signed-in session with a seeded local store, without touching the server.
    static func seed(_ appState: AppState) {
        ScreenshotDemoData.seedConversations()
        appState.currentUserId = "demo-self"
        appState.currentUserDisplayName = "Alex Carter"
        appState.currentUserDialExtension = "104"
        appState.isAuthenticated = true
        if scene == "chat" || scene == "location" {
            let target = scene == "chat" ? ScreenshotDemoData.jamesId : ScreenshotDemoData.sofiaId
            // The list may not be on screen yet (a slow runner): ask again until the chat screen has appeared.
            Task { @MainActor in
                for _ in 0..<24 where !chatOpened {
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    if chatOpened { break }
                    appState.pendingDeepLinkConversationId = target
                }
            }
        }
    }

    /// Moves the biggest scroll view of the key window (the in-call content) down by `offset`.
    static func scrollContent(by offset: CGFloat) {
        guard offset > 0,
              let window = UIApplication.shared.connectedScenes
                .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first else { return }
        var best: UIScrollView?
        func walk(_ v: UIView) {
            if let s = v as? UIScrollView, s.contentSize.height > s.bounds.height + 1,
               s.contentSize.height > (best?.contentSize.height ?? 0) {
                best = s
            }
            v.subviews.forEach(walk)
        }
        walk(window)
        guard let s = best else { return }
        let maxY = max(0, s.contentSize.height - s.bounds.height + s.adjustedContentInset.bottom)
        s.setContentOffset(CGPoint(x: 0, y: min(offset, maxY)), animated: false)
    }
}

struct ScreenshotDemoRoot: View {
    var body: some View {
        if ScreenshotDemo.isCallScene {
            ScreenshotDemoCall()
        } else {
            ContentView()
        }
    }
}

private struct ScreenshotDemoCall: View {
    var body: some View {
        let sas = ScreenshotDemo.scene == "call-sas"
        InCallScreen(
            peerDisplayName: "James",
            durationSeconds: sas ? 16 : 12,
            confidence: sas ? 0.91 : 0.92,
            rekeyInSeconds: 288,
            rekeyTotalSeconds: 300,
            codecKbps: 32,
            txKbps: 44,
            rxKbps: 38,
            rttMs: 42,
            bufMs: 24,
            pqcActive: true,
            sasWords: ["GEIGER", "OBTUSE", "DRUNKEN", "UNEARTH", "WAFFLE", "AFFLICT"],
            sasVerified: false,
            keyInfo: .init(pqcAlgorithm: "ML-KEM-1024 + X25519",
                           sessionFingerprint: "4808f444\u{2026}b1bd",
                           pskMethodLabel: "NFC",
                           pskName: "Key 1",
                           pskFingerprint: "a83c-9f12"),
            hasSessionKey: true,
            transportMode: .p2pSrtp,
            voiceBiometrics: .init(stressScore: 0.2, jitter: 0.012, shimmer: 0.05, hnr: 22,
                                   breathiness: 0.2, pitchHz: 112, syllablesPerSec: 4.2,
                                   confidence: 0.92, f1: 520, f2: 1500, f3: 2500, f4: 3500,
                                   voiceWord: .voice),
            voiceSpectrum: ScreenshotDemoData.spectrum(seed: 3),
            voiceReference: ScreenshotDemoData.spectrum(seed: 1),
            cryptoOpsPerSec: 50,
            peerVoiceKeyEnrolled: true,
            onHangup: {},
            voiceConfidenceHistory: (0..<60).map { 0.86 + 0.06 * Float(sin(Double($0) / 5.0)) },
            peerOwnerContinuityLevel: .verified,
            contactVoiceLevel: .verified
        )
        .qAudionTheme(dark: true)
        .onAppear {
            let offset = ScreenshotDemo.scrollOffset
            Task { @MainActor in
                for _ in 0..<3 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    ScreenshotDemo.scrollContent(by: offset)
                }
            }
        }
    }
}

// MARK: - Data

enum ScreenshotDemoData {

    static let jamesId = UUID(uuidString: "00000000-0000-4000-8000-0000000000A1")!
    static let sofiaId = UUID(uuidString: "00000000-0000-4000-8000-0000000000A2")!
    private static let danielId = UUID(uuidString: "00000000-0000-4000-8000-0000000000A3")!
    private static let emmaId = UUID(uuidString: "00000000-0000-4000-8000-0000000000A4")!

    /// 40 bands in 0...1, a voice-like slope with a few peaks.
    static func spectrum(seed: Int) -> [Float] {
        (0..<40).map { i in
            let x = Float(i)
            let slope = max(0, 0.85 - x * 0.018)
            let ripple = 0.18 * Float(abs(sin(Double(i * (seed + 2)) / 3.0)))
            return min(1, max(0.03, slope * (0.55 + ripple)))
        }
    }

    private enum Lang { case it, en, fr, de, es, pt }

    private static var lang: Lang {
        let code = (Locale.preferredLanguages.first ?? "en").lowercased()
        if code.hasPrefix("it") { return .it }
        if code.hasPrefix("fr") { return .fr }
        if code.hasPrefix("de") { return .de }
        if code.hasPrefix("es") { return .es }
        if code.hasPrefix("pt") { return .pt }
        return .en
    }

    private static func t(_ it: String, _ en: String, _ fr: String, _ de: String, _ es: String, _ pt: String) -> String {
        switch lang {
        case .it: return it
        case .en: return en
        case .fr: return fr
        case .de: return de
        case .es: return es
        case .pt: return pt
        }
    }

    private static func today(_ hour: Int, _ minute: Int) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
    }

    static func seedConversations() {
        let store = ConversationStore()

        let james: [(Message.Direction, String, Int)] = [
            (.incoming, t("Ci vediamo alle 20 al ristorante?",
                          "Still on for dinner at 8?",
                          "On se retrouve toujours à 20 h au restaurant ?",
                          "Treffen wir uns um 20 Uhr im Restaurant?",
                          "¿Quedamos a las 20 h en el restaurante?",
                          "Vamos jantar às 20h no restaurante?"), 24),
            (.outgoing, t("Sì, prenoto io il tavolo.",
                          "Yes, I'll book the table.",
                          "Oui, je réserve la table.",
                          "Ja, ich reserviere den Tisch.",
                          "Sí, reservo yo la mesa.",
                          "Vamos, eu reservo a mesa."), 27),
            (.incoming, t("Perfetto. Mandami l'indirizzo appena puoi.",
                          "Perfect. Send me the address when you can.",
                          "Parfait. Envoie-moi l'adresse dès que possible.",
                          "Perfekt. Schick mir bitte die Adresse.",
                          "Perfecto. Mándame la dirección cuando puedas.",
                          "Perfeito. Me manda o endereço quando puder."), 31),
            (.outgoing, t("Fatto, te l'ho appena inviata.",
                          "Done, just sent it to you.",
                          "C'est fait, je viens de te l'envoyer.",
                          "Erledigt, ich habe sie dir gerade geschickt.",
                          "Hecho, acabo de enviártela.",
                          "Feito, acabei de enviar."), 34),
        ]
        var lastPreview = ""
        var lastDate = today(9, 34)
        // The conversation row first: the messages reference it.
        store.upsertConversation(Conversation(
            id: jamesId, peerUserId: "demo-james", peerDisplayName: "James",
            lastMessagePreview: nil, lastActivity: lastDate,
            unreadCount: 0, pinned: false))
        for (idx, m) in james.enumerated() {
            let at = today(9, m.2)
            let isOut = m.0 == .outgoing
            store.appendMessage(Message(
                id: UUID(uuidString: "00000000-0000-4000-8000-00000000B10\(idx)")!,
                conversationId: jamesId,
                direction: m.0,
                plaintext: m.1,
                sentAt: at,
                deliveredAt: isOut ? at : nil,
                readAt: isOut ? at : nil,
                status: isOut ? .read : .delivered,
                senderUserId: isOut ? nil : "demo-james",
                clientMsgId: "demo-james-\(idx)"))
            lastPreview = m.1
            lastDate = at
        }
        store.upsertConversation(Conversation(
            id: jamesId, peerUserId: "demo-james", peerDisplayName: "James",
            lastMessagePreview: lastPreview, lastActivity: lastDate,
            unreadCount: 0, pinned: false))

        // Sofia: a short exchange with a shared position (a pin, drawn locally as a card).
        let sofia: [(Message.Direction, String, Int)] = [
            (.incoming, t("Dove sei?", "Where are you?", "T'es où ?", "Wo bist du?", "¿Dónde estás?", "Cadê você?"), 36),
            (.outgoing, #"{"qa_loc":1,"m":"pin","lat":454642110,"lon":91899820,"acc":12,"age":3,"ap":0}"#, 37),
            (.incoming, t("Ti vedo, arrivo tra 5 minuti.", "I see you, be there in 5 minutes.",
                          "Je te vois, j'arrive dans 5 minutes.", "Ich sehe dich, bin in 5 Minuten da.",
                          "Te veo, llego en 5 minutos.", "Já vi, chego em 5 minutos."), 38),
        ]
        var sofiaPreview = ""
        store.upsertConversation(Conversation(
            id: sofiaId, peerUserId: "demo-sofia", peerDisplayName: "Sofia",
            lastMessagePreview: nil, lastActivity: today(9, 38),
            unreadCount: 0, pinned: false))
        for (idx, m) in sofia.enumerated() {
            let at = today(9, m.2)
            let isOut = m.0 == .outgoing
            store.appendMessage(Message(
                id: UUID(uuidString: "00000000-0000-4000-8000-00000000D30\(idx)")!,
                conversationId: sofiaId,
                direction: m.0,
                plaintext: m.1,
                sentAt: at,
                deliveredAt: at,
                readAt: isOut ? at : at,
                status: isOut ? .read : .delivered,
                senderUserId: isOut ? nil : "demo-sofia",
                clientMsgId: "demo-sofia-\(idx)"))
            sofiaPreview = m.1
        }
        store.upsertConversation(Conversation(
            id: sofiaId, peerUserId: "demo-sofia", peerDisplayName: "Sofia",
            lastMessagePreview: sofiaPreview, lastActivity: today(9, 38),
            unreadCount: 0, pinned: false))

        let others: [(UUID, String, String, String, Int, Int)] = [
            (danielId, "demo-daniel", "Daniel",
             t("Chiamami quando sei libero.", "Call me when you're free.",
               "Appelle-moi quand tu es libre.", "Ruf mich an, wenn du Zeit hast.",
               "Llámame cuando estés libre.", "Me liga quando estiver livre."), 2, 9),
            (emmaId, "demo-emma", "Emma",
             t("Buon viaggio! Scrivimi all'arrivo.", "Safe travels! Text me when you land.",
               "Bon voyage ! Écris-moi à l'arrivée.", "Gute Reise! Schreib mir bei der Ankunft.",
               "¡Buen viaje! Escríbeme al llegar.", "Boa viagem! Me escreve quando chegar."), 0, 7),
        ]
        for (idx, o) in others.enumerated() {
            let at = today(o.5, 12 + idx * 5)
            store.upsertConversation(Conversation(
                id: o.0, peerUserId: o.1, peerDisplayName: o.2,
                lastMessagePreview: nil, lastActivity: at,
                unreadCount: o.4, pinned: false))
            store.appendMessage(Message(
                id: UUID(uuidString: "00000000-0000-4000-8000-00000000C20\(idx)")!,
                conversationId: o.0,
                direction: .incoming,
                plaintext: o.3,
                sentAt: at,
                deliveredAt: at,
                readAt: o.4 == 0 ? at : nil,
                status: .delivered,
                senderUserId: o.1,
                clientMsgId: "demo-other-\(idx)"))
            store.upsertConversation(Conversation(
                id: o.0, peerUserId: o.1, peerDisplayName: o.2,
                lastMessagePreview: o.3, lastActivity: at,
                unreadCount: o.4, pinned: false))
        }
    }
}
#endif
