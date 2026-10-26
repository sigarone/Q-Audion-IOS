//
//  CarPlayScene.swift — Q-Audion in-car UI (Tier B, custom CarPlay app)
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
//  What the lists contain, and how many rows they may have, is decided in
//  `CarPlayListModel.swift`, which is compiled in every build and unit tested.
//  This file only draws it.
//
//  ── HOW IT IS BUILT ────────────────────────────────────────────────────
//  This file is part of every build of the app. `project.yml` links CarPlay.framework, the app's Info.plist declares
//  the scene (role CPTemplateApplicationSceneSessionRoleApplication, delegate `CarPlaySceneDelegate`, multiple
//  scenes on) and `QAudion.entitlements` / `QAudionVPN.entitlements` carry
//  `com.apple.developer.carplay-communication`. `scripts/ci/check_carplay_gating.py` fails a pull request that
//  drops any of them, and `ios-app-tests.yml` checks the built app for all of them.
//

import CarPlay
import UIKit
import Combine
import QAudionEngine

@available(iOS 16.0, *)
@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate, CPSessionConfigurationDelegate {

    private var interfaceController: CPInterfaceController?
    private var carSession: CPSessionConfiguration?

    /// How many rows the lists may show. Starts at the strictest case and follows what the template and the vehicle
    /// report once the session exists.
    private var limits: CarPlayListLimits = .conservative

    // One store instance reused for the session (ConversationStore() runs a
    // one-time migration on init; constructing it per reload would be wasteful).
    private let conversationStore = ConversationStore()
    private let contactsStore = ContactsStore()

    // W-L10N-BATCH1 (2026-09-08) — CPListTemplate/CPListItem/CPContact/
    // CPMessageListItem all take plain `String`, not SwiftUI's
    // `LocalizedStringKey` — none of this file auto-localizes just by a
    // String Catalog existing, unlike the Text()/Button() literals
    // elsewhere in the app. Every fixed UI-chrome string below is now
    // routed through String(localized:) with a stable key; dynamic values
    // (contact names, call-record display names) are left untouched.
    private let recentsTemplate = CPListTemplate(
        title: String(localized: "carplay.tab.recents", defaultValue: "Recenti", comment: "CarPlay tab title — recent calls list"),
        sections: [])
    private let contactsTemplate = CPListTemplate(
        title: String(localized: "carplay.tab.contacts", defaultValue: "Contatti", comment: "CarPlay tab title — contacts list"),
        sections: [])
    private let messagesTemplate = CPListTemplate(
        title: String(localized: "carplay.tab.messages", defaultValue: "Messaggi", comment: "CarPlay tab title — conversations list"),
        sections: [])

    private var recordsCancellable: AnyCancellable?
    private var contactsObserver: NSObjectProtocol?

    // MARK: - Lifecycle

    /// The car starts the app with only this scene when the phone has no window, so everything the app needs is
    /// started from here (`CarPlayBridge.carPlayConnected()` runs the app's start-up first) and nothing below relies on
    /// the phone's window having appeared.
    func templateApplicationScene(
        _ scene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController

        CarPlayBridge.shared.noticeSink = { [weak self] notice in
            Task { @MainActor in self?.present(notice) }
        }
        // A launch made by the car starts with the session still being restored, and the app lock can change while the
        // car is connected: the lists follow both.
        CarPlayBridge.shared.onSignInChanged = { [weak self] in self?.reloadAll() }
        CarPlayBridge.shared.onLockChanged = { [weak self] in self?.reloadAll() }
        CarPlayBridge.shared.carPlayConnected()

        carSession = CPSessionConfiguration(delegate: self)
        refreshLimits()

        recentsTemplate.tabSystemItem = .recents
        contactsTemplate.tabSystemItem = .contacts
        messagesTemplate.tabTitle = String(localized: "carplay.tab.messages", defaultValue: "Messaggi", comment: "CarPlay tab title — conversations list")
        messagesTemplate.tabImage = UIImage(systemName: "message.fill")

        // CarPlay/Siri state-of-the-art plan S4 — the assistant cell needs
        // nothing beyond S1 (INStartCallIntent): Apple's own doc says a
        // communication app's assistant cell action must be `.startCall`,
        // and "your app must include an Intents Extension that handles"
        // that intent — QAudionIntents/IntentHandler.swift already does.
        // Only on Recenti, mirroring a Phone app's own Recents tab.
        recentsTemplate.assistantCellConfiguration = CPAssistantCellConfiguration(
            position: .top, visibility: .always, assistantAction: .startCall)

        let tabBar = CPTabBarTemplate(templates: [
            recentsTemplate, contactsTemplate, messagesTemplate
        ])
        interfaceController.setRootTemplate(tabBar, animated: true, completion: nil)

        reloadAll()
        startObserving()
    }

    func templateApplicationScene(
        _ scene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        stopObserving()
        self.interfaceController = nil
        self.carSession = nil
        CarPlayBridge.shared.carPlayDisconnected()
    }

    // MARK: - Siri

    /// A cold launch from Siri ("call X on Q-Audion") that reaches only this scene carries the request in its
    /// connection options.
    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        for activity in connectionOptions.userActivities {
            CarPlayBridge.shared.deliverSiriActivity(activity)
        }
    }

    /// A Siri request that arrives while the scene is already up.
    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        CarPlayBridge.shared.deliverSiriActivity(userActivity)
    }

    // MARK: - Limits

    private func refreshLimits() {
        let limited: Bool = carSession?.limitedUserInterfaces.contains(.lists) ?? true
        limits = CarPlayListLimits(
            templateMaximumItems: CPListTemplate.maximumItemCount, listsLimited: limited)
    }

    func sessionConfiguration(
        _ sessionConfiguration: CPSessionConfiguration,
        limitedUserInterfacesChanged limitedUserInterfaces: CPLimitableUserInterface
    ) {
        refreshLimits()
        reloadAll()
    }

    func sessionConfiguration(
        _ sessionConfiguration: CPSessionConfiguration,
        contentStyleChanged contentStyle: CPContentStyle
    ) {}

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
            .sink { [weak self] _ in
                Task { @MainActor in self?.reloadRecents() }
            }
        // Contacts list change → refresh contacts + messages (a new contact may
        // change a conversation's display name). ConversationStore has no
        // publisher, so the messages tab also refreshes on connect.
        contactsObserver = NotificationCenter.default.addObserver(
            forName: .contactsDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.reloadContacts()
                self?.reloadMessages()
            }
        }
    }

    private func stopObserving() {
        recordsCancellable?.cancel()
        recordsCancellable = nil
        if let o = contactsObserver { NotificationCenter.default.removeObserver(o) }
        contactsObserver = nil
    }

    private func reloadAll() {
        // A detail screen pushed before the app lock went up must not stay on the car screen.
        if currentAccess() != .open, let controller = interfaceController, controller.templates.count > 1 {
            controller.popToRootTemplate(animated: false, completion: nil)
        }
        reloadRecents()
        reloadContacts()
        reloadMessages()
    }

    /// What the lists may show: nothing while the session is not known, while nobody is signed in, or while the app
    /// lock is up.
    private func currentAccess() -> CarPlayAccess {
        CarPlayListBuilder.access(
            session: CarPlayBridge.shared.currentSession(), isLocked: CarPlayBridge.shared.appIsLocked())
    }

    /// Names are resolved against one snapshot of the address book per reload, not one read per row.
    private func nameResolver() -> (String) -> String {
        let snapshot = contactsStore.load()
        return { userId in DisplayName.forUser(userId, contacts: snapshot) }
    }

    // MARK: - Calling

    /// Starts a call from a row or a button. If the app cannot take the request the driver is told, on the car screen.
    private func startCall(peerUserId: String, label: String) {
        switch CarPlayBridge.shared.requestCall(peerUserId: peerUserId, displayName: label) {
        case .handedOver: break
        case .appNotReady: present(.notReady)
        case .locked: present(.appLocked)
        }
    }

    // MARK: - Recenti

    private func reloadRecents() {
        let access = currentAccess()
        defer { applyEmptyState(.recents, to: recentsTemplate, access: access) }
        guard access == .open else {
            recentsTemplate.updateSections([])
            return
        }
        let rows = CarPlayListBuilder.recents(
            PersistentCallRecordStore.shared.records, limits: limits, resolve: nameResolver())
        let items: [CPListItem] = rows.map { row in
            let item = CPListItem(text: row.title, detailText: Self.recentSubtitle(row))
            item.handler = { [weak self] _, completion in
                Task { @MainActor in self?.startCall(peerUserId: row.peerUserId, label: row.title) }
                completion()
            }
            return item
        }
        recentsTemplate.updateSections(items.isEmpty ? [] : [CPListSection(items: items)])
    }

    private static func recentSubtitle(_ row: CarPlayRecentRow) -> String {
        var parts: [String] = []
        switch row.direction {
        case .incoming: parts.append(String(localized: "carplay.recents.direction.incoming", defaultValue: "In entrata", comment: "CarPlay recents row — call direction"))
        case .outgoing: parts.append(String(localized: "carplay.recents.direction.outgoing", defaultValue: "In uscita", comment: "CarPlay recents row — call direction"))
        case .missed:   parts.append(String(localized: "carplay.recents.direction.missed", defaultValue: "Persa", comment: "CarPlay recents row — call direction"))
        }
        if let d = row.durationSeconds {
            parts.append(CarPlayListBuilder.formatDuration(d))
        }
        if row.isVideo {
            parts.append(String(localized: "carplay.recents.video_tag", defaultValue: "Video", comment: "CarPlay recents row — tag marking a video call"))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Contatti

    private func reloadContacts() {
        let access = currentAccess()
        defer { applyEmptyState(.contacts, to: contactsTemplate, access: access) }
        guard access == .open else {
            contactsTemplate.updateSections([])
            return
        }
        // CarPlay/Siri state-of-the-art plan S4 — a row tap PUSHES a
        // CPContactTemplate (contact detail: call + optional message
        // button) instead of dialing immediately.
        let rows = CarPlayListBuilder.contacts(
            contactsStore.load(), orphanPeerIds: CarPlayBridge.shared.orphanPeerIds,
            limits: limits, resolve: nameResolver())
        let items: [CPListItem] = rows.map { row in
            let item = CPListItem(
                text: row.title,
                detailText: row.isVerified
                    ? String(localized: "carplay.contacts.verified", defaultValue: "Verificato", comment: "CarPlay contact row — verified badge")
                    : nil)
            item.handler = { [weak self] _, completion in
                Task { @MainActor in
                    self?.pushContactDetail(userId: row.userId, displayName: row.title, phoneNumber: row.phoneNumber)
                }
                completion()
            }
            return item
        }
        contactsTemplate.updateSections(items.isEmpty ? [] : [CPListSection(items: items)])
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
            CPContactCallButton { [weak self] _ in
                Task { @MainActor in self?.startCall(peerUserId: userId, label: displayName) }
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
    /// rows. `CPMessageListItem` has no `handler`: selecting a row
    /// with no unread indicator launches Siri's REPLY flow (routes to
    /// `IntentHandler`'s `INSendMessageIntentHandling`); one WITH an unread
    /// indicator launches the READ flow (`INSearchForMessagesIntentHandling`,
    /// reading from `SiriMessageBridgeStore`'s opt-in cache). Either way
    /// Siri does the talking, and it names the conversation through
    /// `conversationIdentifier`, which the handlers honour. This screen's own
    /// `text`/`detailText` deliberately carry only the peer's name and an
    /// unread count, never message content.
    private func reloadMessages() {
        let access = currentAccess()
        defer { applyEmptyState(.messages, to: messagesTemplate, access: access) }
        guard access == .open else {
            messagesTemplate.updateSections([])
            updatePinnedGrid([])
            return
        }
        let resolve = nameResolver()
        let all = conversationStore.loadConversations()
        let rows = CarPlayListBuilder.conversations(all, limits: limits, resolve: resolve)
        let items: [CPMessageListItem] = rows.map { row in
            let unread = row.unreadCount > 0
            let leadingConfig = CPMessageListItemLeadingConfiguration(
                leadingItem: row.isPinned ? .pin : .none, leadingImage: nil, unread: unread)
            let detail = unread
                ? String(localized: "carplay.messages.unread_count", defaultValue: "\(row.unreadCount) non letti", comment: "CarPlay conversation row — unread message count, %lld is the count")
                : nil
            return CPMessageListItem(
                conversationIdentifier: row.conversationIdentifier,
                text: row.title,
                leadingConfiguration: leadingConfig,
                trailingConfiguration: nil,
                detailText: detail,
                trailingText: nil)
        }
        messagesTemplate.updateSections(items.isEmpty ? [] : [CPListSection(items: items)])
        updatePinnedGrid(CarPlayListBuilder.pinnedConversations(
            all, maximum: Self.maximumPinnedButtons(), resolve: resolve))
    }

    /// iOS 26 puts pinned conversations in a grid above the list. Older systems have no such header, so there are
    /// none to fill.
    private static func maximumPinnedButtons() -> Int {
        if #available(iOS 26.0, *) { return CPListTemplate.maximumHeaderGridButtonCount }
        return 0
    }

    private func updatePinnedGrid(_ pinned: [CarPlayConversationRow]) {
        guard #available(iOS 26.0, *) else { return }
        let image = UIImage(systemName: "person.crop.circle.fill") ?? UIImage()
        let buttons: [CPGridButton] = pinned.map { row in
            CPGridButton(
                titleVariants: [row.title],
                image: image,
                messageConfiguration: CPMessageGridItemConfiguration(
                    conversationIdentifier: row.conversationIdentifier, unread: row.unreadCount > 0),
                handler: nil)
        }
        messagesTemplate.headerGridButtons = buttons.isEmpty ? nil : buttons
    }

    // MARK: - Empty states and notices
    //
    // Nothing on the car screen may tell the driver to use the phone: a CarPlay flow has to be possible without
    // touching it. Every state below says what is (or is not) there and stops.

    private func applyEmptyState(_ tab: CarPlayTab, to template: CPListTemplate, access: CarPlayAccess) {
        let (title, subtitle) = Self.emptyCopy(CarPlayListBuilder.emptyKind(for: tab, access: access))
        template.emptyViewTitleVariants = [title]
        template.emptyViewSubtitleVariants = [subtitle]
    }

    private static func emptyCopy(_ kind: CarPlayEmptyKind) -> (title: String, subtitle: String) {
        switch kind {
        case .starting:
            return (
                String(localized: "carplay.empty.starting.title", defaultValue: "Q-Audion si sta avviando", comment: "CarPlay empty state title — the app is starting and the account is being checked"),
                String(localized: "carplay.empty.starting.subtitle", defaultValue: "Verifica dell'account in corso", comment: "CarPlay empty state subtitle — the account is being checked"))
        case .locked:
            return (
                String(localized: "carplay.empty.locked.title", defaultValue: "Q-Audion bloccato", comment: "CarPlay empty state title — the app lock is on"),
                String(localized: "carplay.empty.locked.subtitle", defaultValue: "Il blocco dell'app è attivo", comment: "CarPlay empty state subtitle — the app lock is on"))
        case .signedOut:
            return (
                String(localized: "carplay.empty.signed_out.title", defaultValue: "Q-Audion non disponibile", comment: "CarPlay empty state title — no account is signed in"),
                String(localized: "carplay.empty.signed_out.subtitle", defaultValue: "Nessun account attivo", comment: "CarPlay empty state subtitle — no account is signed in"))
        case .nothingYet(.recents):
            return (
                String(localized: "carplay.recents.empty.title", defaultValue: "Nessuna chiamata recente", comment: "CarPlay recents tab — empty state title"),
                String(localized: "carplay.recents.empty.subtitle", defaultValue: "Le chiamate sicure compaiono qui", comment: "CarPlay recents tab — empty state subtitle"))
        case .nothingYet(.contacts):
            return (
                String(localized: "carplay.contacts.empty.title", defaultValue: "Nessun contatto", comment: "CarPlay contacts tab — empty state title"),
                String(localized: "carplay.contacts.empty.subtitle", defaultValue: "I contatti Q-Audion compaiono qui", comment: "CarPlay contacts tab — empty state subtitle"))
        case .nothingYet(.messages):
            return (
                String(localized: "carplay.messages.empty.title", defaultValue: "Nessuna conversazione", comment: "CarPlay messages tab — empty state title"),
                String(localized: "carplay.messages.empty.subtitle", defaultValue: "Le conversazioni cifrate compaiono qui", comment: "CarPlay messages tab — empty state subtitle"))
        }
    }

    private static func noticeTitle(_ notice: CarPlayNotice) -> String {
        switch notice {
        case .contactNotFound:
            return String(localized: "carplay.notice.contact_not_found", defaultValue: "Contatto non trovato", comment: "CarPlay alert — the requested contact is not one the app can call")
        case .callNotStarted:
            return String(localized: "carplay.notice.call_not_started", defaultValue: "Chiamata non avviata", comment: "CarPlay alert — a call could not be started")
        case .notReady:
            return String(localized: "carplay.notice.not_ready", defaultValue: "Q-Audion non è ancora pronto", comment: "CarPlay alert — the app cannot take the request yet")
        case .appLocked:
            return String(localized: "carplay.notice.app_locked", defaultValue: "Q-Audion è bloccato", comment: "CarPlay alert — the app lock is on, so no call is placed")
        }
    }

    /// A short modal alert with one button. Skipped while another template is already presented.
    private func present(_ notice: CarPlayNotice) {
        guard let interfaceController, interfaceController.presentedTemplate == nil else { return }
        let ok = CPAlertAction(
            title: String(localized: "carplay.notice.ok", defaultValue: "OK", comment: "CarPlay alert — dismiss button"),
            style: .default
        ) { [weak self] _ in
            Task { @MainActor in self?.interfaceController?.dismissTemplate(animated: true, completion: nil) }
        }
        let alert = CPAlertTemplate(titleVariants: [Self.noticeTitle(notice)], actions: [ok])
        interfaceController.presentTemplate(alert, animated: true, completion: nil)
    }
}
