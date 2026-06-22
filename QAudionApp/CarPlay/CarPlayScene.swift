//
//  CarPlayScene.swift — Q-Audion in-car UI (Tier B, custom CarPlay app)
//
//  ┌──────────────────────────────────────────────────────────────────────┐
//  │  GATED BEHIND `QAUDION_CARPLAY`. OFF by default → this whole file is    │
//  │  excluded from compilation so `v*` TestFlight tag builds stay GREEN     │
//  │  without the (Apple-approval-gated) CarPlay entitlement.                │
//  └──────────────────────────────────────────────────────────────────────┘
//
//  ── TIER A (works TODAY, no code, no entitlement) ───────────────────────
//  Incoming + active calls already surface on CarPlay automatically because
//  the engine drives CallKit (see CallKitProvider.swift). Answer / end / mute
//  appear on the head unit with ZERO changes. Nothing here is needed for that.
//
//  ── TIER B (this file — custom in-car app, parity with Android Auto) ─────
//  A CarPlay app icon on the head-unit home screen with a tab bar:
//     • Recenti  — last secure calls            (mirrors Android CallListScreen)
//     • Contatti — verified contacts, quick-dial (mirrors quick-dial rows)
//     • Messaggi — read-only conversation list   (mirrors MessageListScreen;
//                  plaintext is NEVER surfaced — driving-safety + privacy,
//                  same rule as Android. Tap = call that peer.)
//
//  ── HOW TO ENABLE (after Apple grants the entitlement) ──────────────────
//  1. Request entitlement:  developer.apple.com/contact/request/carplay-entitlement
//     category = "Communication app" → `com.apple.developer.carplay-communication`.
//     (Free, discretionary, can take weeks. NOT MFi — no hardware program.)
//  2. Add to QAudion.entitlements:
//        <key>com.apple.developer.carplay-communication</key><true/>
//  3. Add the CarPlay scene to Info.plist (set MultipleScenes = true):
//        <key>UIApplicationSceneManifest</key><dict>
//          <key>UIApplicationSupportsMultipleScenes</key><true/>
//          <key>UISceneConfigurations</key><dict>
//            <key>CPTemplateApplicationSceneSessionRoleApplication</key><array><dict>
//              <key>UISceneConfigurationName</key><string>QAudionCarPlay</string>
//              <key>UISceneDelegateClassName</key>
//              <string>$(PRODUCT_MODULE_NAME).CarPlaySceneDelegate</string>
//            </dict></array>
//          </dict>
//        </dict>
//  4. Turn on the compile flag (project.yml → SWIFT_ACTIVE_COMPILATION_CONDITIONS
//     += QAUDION_CARPLAY) and re-run xcodegen. CarPlay.framework is already
//     linked (inert until the scene is created), so no other build change.
//

#if QAUDION_CARPLAY
import CarPlay
import UIKit
import Combine
import QAudionEngine

@available(iOS 16.0, *)
@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {

    private var interfaceController: CPInterfaceController?

    // One store instance reused for the session (ConversationStore() runs a
    // one-time migration on init; constructing it per reload would be wasteful).
    private let conversationStore = ConversationStore()
    private let contactsStore = ContactsStore()

    private let recentsTemplate = CPListTemplate(title: "Recenti", sections: [])
    private let contactsTemplate = CPListTemplate(title: "Contatti", sections: [])
    private let messagesTemplate = CPListTemplate(title: "Messaggi", sections: [])

    private var recordsCancellable: AnyCancellable?
    private var contactsObserver: NSObjectProtocol?

    // MARK: - Lifecycle

    func templateApplicationScene(
        _ scene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController

        recentsTemplate.tabSystemItem = .recents
        contactsTemplate.tabSystemItem = .contacts
        messagesTemplate.tabTitle = "Messaggi"
        messagesTemplate.tabImage = UIImage(systemName: "message.fill")

        configureEmptyStates()

        let tabBar = CPTabBarTemplate(templates: [
            recentsTemplate, contactsTemplate, messagesTemplate
        ])
        interfaceController.setRootTemplate(tabBar, animated: true, completion: nil)

        reloadAll()
        startObserving()
        CarPlayBridge.shared.carPlayConnected()
    }

    func templateApplicationScene(
        _ scene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        stopObserving()
        self.interfaceController = nil
        CarPlayBridge.shared.carPlayDisconnected()
    }

    // MARK: - Live refresh

    private func startObserving() {
        // Recents — refresh on every PersistentCallRecordStore mutation.
        // Use `objectWillChange` (always public via ObservableObject) rather
        // than `$records` (whose projected value is `public private(set)` and
        // may not be visible cross-module). `receive(on: .main)` defers the
        // reload to the next run-loop tick, by which point the @Published
        // mutation has completed, so `.records` reads the fresh value.
        recordsCancellable = PersistentCallRecordStore.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reloadRecents() }
        // Contacts list change → refresh contacts + messages (a new contact may
        // change a conversation's display name). ConversationStore has no
        // publisher, so the messages tab also refreshes on connect.
        contactsObserver = NotificationCenter.default.addObserver(
            forName: .contactsDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.reloadContacts()
            self?.reloadMessages()
        }
    }

    private func stopObserving() {
        recordsCancellable?.cancel()
        recordsCancellable = nil
        if let o = contactsObserver { NotificationCenter.default.removeObserver(o) }
        contactsObserver = nil
    }

    private func reloadAll() {
        reloadRecents()
        reloadContacts()
        reloadMessages()
    }

    // MARK: - Recenti

    private func reloadRecents() {
        let records = Array(PersistentCallRecordStore.shared.records.prefix(20))
        let items: [CPListItem] = records.map { rec in
            let item = CPListItem(text: rec.peerDisplayName,
                                  detailText: Self.recentSubtitle(rec))
            item.handler = { _, completion in
                CarPlayBridge.shared.requestCall(
                    peerUserId: rec.peerUserId, displayName: rec.peerDisplayName)
                completion()
            }
            return item
        }
        recentsTemplate.updateSections([CPListSection(items: items)])
    }

    private static func recentSubtitle(_ rec: CallRecord) -> String {
        var parts: [String] = []
        switch rec.direction {
        case .incoming: parts.append("In entrata")
        case .outgoing: parts.append("In uscita")
        case .missed:   parts.append("Persa")
        }
        if let d = rec.durationSeconds {
            parts.append(formatDuration(d))
        }
        if rec.isVideo { parts.append("Video") }
        return parts.joined(separator: " · ")
    }

    private static func formatDuration(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%02d:%02d", m, s)
    }

    // MARK: - Contatti

    private func reloadContacts() {
        // Verified first, then alphabetical; cap at 50 rows for the head unit.
        let contacts = contactsStore.load()
            .sorted { lhs, rhs in
                if lhs.isVerified != rhs.isVerified { return lhs.isVerified }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
            .prefix(50)

        let items: [CPListItem] = contacts.map { c in
            let item = CPListItem(text: c.displayName,
                                  detailText: c.isVerified ? "Verificato" : nil)
            item.handler = { _, completion in
                CarPlayBridge.shared.requestCall(
                    peerUserId: c.userId, displayName: c.displayName)
                completion()
            }
            return item
        }
        contactsTemplate.updateSections([CPListSection(items: items)])
    }

    // MARK: - Messaggi (read-only; plaintext NEVER surfaced — tap calls peer)

    private func reloadMessages() {
        // 1:1 only — tapping a row places a call to that peer, which has no
        // meaning for a group conversation (no single callable peerUserId).
        let convs = conversationStore.loadConversations()
            .filter { $0.kind == .oneToOne }
            .prefix(20)
        let items: [CPListItem] = convs.map { conv in
            let detail: String = conv.unreadCount > 0
                ? "\(conv.unreadCount) non letti · Tocca per chiamare"
                : "Tocca per chiamare"
            let item = CPListItem(text: conv.peerDisplayName, detailText: detail)
            item.handler = { _, completion in
                CarPlayBridge.shared.requestCall(
                    peerUserId: conv.peerUserId, displayName: conv.peerDisplayName)
                completion()
            }
            return item
        }
        messagesTemplate.updateSections([CPListSection(items: items)])
    }

    // MARK: - Empty states

    private func configureEmptyStates() {
        recentsTemplate.emptyViewTitleVariants = ["Nessuna chiamata recente"]
        recentsTemplate.emptyViewSubtitleVariants =
            ["Le chiamate sicure compaiono qui"]
        contactsTemplate.emptyViewTitleVariants = ["Nessun contatto"]
        contactsTemplate.emptyViewSubtitleVariants =
            ["Aggiungi contatti dall'app sul telefono"]
        messagesTemplate.emptyViewTitleVariants = ["Nessuna conversazione"]
        messagesTemplate.emptyViewSubtitleVariants =
            ["Tocca un contatto per chiamare in sicurezza"]
    }
}
#endif
