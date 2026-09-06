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
//     • Recenti  — last secure calls + Siri assistant cell (S1/S4, mirrors
//                  Android CallListScreen)
//     • Contatti — verified contacts; tap pushes a CPContactTemplate with
//                  a call button (direct, no Siri) and — when the contact
//                  has a known phone/email — a CPContactMessageButton (S4,
//                  Siri compose flow, needs S2's INSendMessageIntent)
//     • Messaggi — CPMessageListItem rows (S5): plaintext is NEVER drawn on
//                  screen (driving-safety + privacy, same rule as Android),
//                  but Siri can read/reply to a selected conversation
//                  through S2's INSearchForMessagesIntent/INSendMessageIntent
//                  (SiriMessageBridgeStore's opt-in cache/outbox) — the
//                  screen itself still shows only names/unread counts.
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

        // CarPlay/Siri state-of-the-art plan S4 — the assistant cell needs
        // nothing beyond S1 (INStartCallIntent): Apple's own doc says a
        // communication app's assistant cell action must be `.startCall`,
        // and "your app must include an Intents Extension that handles"
        // that intent — QAudionIntents/IntentHandler.swift already does.
        // Only on Recenti, mirroring a Phone app's own Recents tab.
        recentsTemplate.assistantCellConfiguration = CPAssistantCellConfiguration(
            position: .top, visibility: .always, assistantAction: .startCall)

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
            let carTitle = DisplayName.looksLikeUUID(rec.peerDisplayName) || rec.peerDisplayName.isEmpty
                ? DisplayName.forUser(rec.peerUserId)
                : rec.peerDisplayName
            let item = CPListItem(text: carTitle,
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
        // W-ORPHANPEER — drop accounts that no longer exist server-side before
        // sorting; these rows dial on tap, so offering a dead account here is
        // the worst version of the bug.
        let orphans = CarPlayBridge.shared.orphanPeerIds
        let contacts = contactsStore.load()
            .filter { !shouldHideContact(orphans.contains($0.userId)) }
            .sorted { lhs, rhs in
                if lhs.isVerified != rhs.isVerified { return lhs.isVerified }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
            .prefix(50)

        // W-EXTPREFIX consolidation (2026-07-29): this used `c.displayName`
        // verbatim — a stale "Phone #100"/"New User" row would render as-is
        // on the head-unit list AND get handed to `requestCall` as the
        // in-call label. Resolved through the canonical `DisplayName
        // .forUser` instead (this file is gated behind `QAUDION_CARPLAY`,
        // off by default, but should not carry the same bug the moment it
        // ships).
        //
        // CarPlay/Siri state-of-the-art plan S4 — a row tap now PUSHES a
        // CPContactTemplate (contact detail: call + optional message
        // button) instead of dialing immediately. One extra tap versus the
        // old direct-dial behavior, accepted deliberately now that the
        // detail screen has a real second action to offer
        // (CPContactMessageButton, S2) — pushing an extra tap for a screen
        // with only a call button would have been a pure regression, which
        // is why this was deferred until S2 existed.
        let items: [CPListItem] = contacts.map { c in
            let resolvedName = DisplayName.forUser(c.userId, contacts: [c])
            let item = CPListItem(text: resolvedName,
                                  detailText: c.isVerified ? "Verificato" : nil)
            item.handler = { [weak self] _, completion in
                self?.pushContactDetail(userId: c.userId, displayName: resolvedName, phoneNumber: c.phoneNumber)
                completion()
            }
            return item
        }
        contactsTemplate.updateSections([CPListSection(items: items)])
    }

    /// CarPlay/Siri state-of-the-art plan S4 — contact-detail push screen.
    /// `CPContactCallButton` calls directly (no Siri round-trip, same as
    /// the old one-tap-dial handler). `CPContactMessageButton` only added
    /// when a phone/email is actually known for this peer (many Q-Audion
    /// contacts — discover-v2/QR-scan imports — never learn one, see
    /// `ContactsStore.StoredContact.phoneNumber`'s own doc) — Siri resolves
    /// it via `IntentHandler`'s `INSendMessageIntentHandling`
    /// (`SiriMessageBridgeStore`'s outbox), never anything in this file.
    private func pushContactDetail(userId: String, displayName: String, phoneNumber: String?) {
        let placeholderImage = UIImage(systemName: "person.crop.circle.fill") ?? UIImage()
        let contact = CPContact(name: displayName, image: placeholderImage)
        var actions: [CPButton] = [
            CPContactCallButton { _ in
                CarPlayBridge.shared.requestCall(peerUserId: userId, displayName: displayName)
            }
        ]
        if let phoneNumber, !phoneNumber.trimmingCharacters(in: .whitespaces).isEmpty {
            actions.append(CPContactMessageButton(phoneOrEmail: phoneNumber))
        }
        contact.actions = actions
        interfaceController?.pushTemplate(CPContactTemplate(contact: contact), animated: true, completion: nil)
    }

    // MARK: - Messaggi (screen NEVER draws plaintext; Siri may read it aloud via S2)

    /// CarPlay/Siri state-of-the-art plan S5 — real `CPMessageListItem`
    /// rows instead of the old `CPListItem`-that-just-calls-the-peer
    /// workaround. `CPMessageListItem` has no `handler`: selecting a row
    /// with no unread indicator launches Siri's REPLY flow (routes to
    /// `IntentHandler`'s `INSendMessageIntentHandling`); one WITH an unread
    /// indicator launches the READ flow (`INSearchForMessagesIntentHandling`,
    /// reading from `SiriMessageBridgeStore`'s opt-in cache). Either way
    /// Siri does the talking — this screen's own `text`/`detailText`
    /// deliberately still carry only the peer's name and an unread count,
    /// never message content, preserving the exact no-plaintext-on-screen
    /// policy the old implementation already had.
    private func reloadMessages() {
        // 1:1 only — INSendMessageIntent/INSearchForMessagesIntent both key
        // off a single peer; a group conversation has no single recipient.
        let convs = conversationStore.loadConversations()
            .filter { $0.kind == .oneToOne }
            .prefix(20)
        let items: [CPMessageListItem] = convs.map { conv in
            let convTitle = DisplayName.looksLikeUUID(conv.peerDisplayName) || conv.peerDisplayName.isEmpty
                ? DisplayName.forUser(conv.peerUserId)
                : conv.peerDisplayName
            let unread = conv.unreadCount > 0
            let leadingConfig = CPMessageListItemLeadingConfiguration(
                leadingItem: .none, leadingImage: nil, unread: unread)
            let detail = unread ? "\(conv.unreadCount) non letti" : nil
            return CPMessageListItem(
                conversationIdentifier: conv.peerUserId,
                text: convTitle,
                leadingConfiguration: leadingConfig,
                trailingConfiguration: nil,
                detailText: detail,
                trailingText: nil)
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
            ["Le conversazioni cifrate compaiono qui"]
    }
}
#endif
