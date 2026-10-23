import Intents

/// SiriKit Intents Extension handler, CarPlay/Siri state-of-the-art plan
/// (docs/superpowers/plans/2026-09-06-carplay-state-of-the-art.md).
///
/// **S1 (`INStartCallIntent`, below)** is a thin pass-through: per Apple's
/// own documentation, an Intents extension must never place the call
/// itself — it only confirms the request is plausible and hands off to the
/// main app, which does the actual Q-Audion contact resolution
/// (`SiriCallResolution`, QAudionEngine) and dials through the exact same
/// `AppState.startCall` path CarPlay and the in-app dial screen already use.
///
/// **S2 (`INSendMessageIntent`/`INSearchForMessagesIntent`/
/// `INSetMessageAttributeIntent`, see the extensions below) CANNOT be a
/// pass-through** — per Apple's own docs, `handle()` for these must send,
/// search or mark from inside this process, there is no hand-off like calls
/// get. Verified via a `cryptography-security-expert` consultation
/// (2026-09-06, recorded in the plan doc): this extension NEVER touches this
/// app's E2EE ratchet/session material. It talks only to
/// `SiriMessageBridgeStore` (`QAudionApp/Siri/SiriMessageBridgeStore.swift`,
/// compiled into this target directly — see that file's header for the full
/// security design) — queuing outgoing text and read marks for the main app
/// to apply later, and reading an opt-in, main-app-populated plaintext cache
/// for search.
///
/// WHO IS A PERSON. The extension has no contact list of its own. A call request
/// passes every person on as Siri gave it: the app matches it after the hand-off
/// and says on the car screen when nobody matches. For a message, a person Siri
/// tied to a contact card (a handle) or that this app donated (a custom
/// identifier) is resolved, and several such candidates are a disambiguation
/// (`SiriIntentPolicy`); a name Siri merely heard is passed on unchanged.
///
/// CONVERSATIONS. A CarPlay conversation row carries the peer's user id as
/// its `conversationIdentifier`; Siri hands it back on the send and search
/// intents, and the handlers honour it before looking at any name.
///
/// Every decision is made by a function that returns a plain value (the
/// `...Outcome` enums); the `resolve...` methods only turn that value into the
/// SiriKit result, so the decisions can be tested with real `INPerson` and
/// intent objects.
///
/// This target still links no `QAudionEngine` at all — an Intents extension
/// runs under a tight, separate memory budget from the host app (the same
/// reason the former ReplayKit broadcast extension, since removed in group
/// calls v2, avoided linking the full engine product).
final class IntentHandler: INExtension, INStartCallIntentHandling {

    private let store: SiriBridgeStoring
    private let messagingConsent: () -> Bool

    /// The bridge the extension's own initializer uses. Tests replace it to see what the handler reads.
    static var productionStore: () -> SiriBridgeStoring = { SiriMessageBridgeStore.shared }

    /// The consent the extension's own initializer uses: the opt-in setting of the app.
    static let settingsConsent: () -> Bool = { SiriMessagingConsent.isEnabled }

    override convenience init() {
        self.init(store: IntentHandler.productionStore(), messagingConsent: IntentHandler.settingsConsent)
    }

    /// For tests: a stand-in bridge and consent.
    init(store: SiriBridgeStoring, messagingConsent: @escaping () -> Bool) {
        self.store = store
        self.messagingConsent = messagingConsent
        super.init()
    }

    override func handler(for intent: INIntent) -> Any {
        return self
    }

    // MARK: - People

    /// What becomes of one person Siri handed over.
    enum PersonOutcome {
        /// The one person that can be tied to somebody.
        case success(INPerson)
        /// Several can: Siri has to ask which.
        case disambiguation([INPerson])
    }

    /// The person's candidates: what Siri matched it to when it found some, else the person itself.
    static func candidates(of person: INPerson) -> [INPerson] {
        if let matches = person.siriMatches, !matches.isEmpty { return matches }
        return [person]
    }

    static func facts(of person: INPerson) -> SiriPersonFacts {
        SiriPersonFacts(
            displayName: person.displayName,
            handle: person.personHandle?.value,
            customIdentifier: person.customIdentifier)
    }

    static func personOutcome(for person: INPerson) -> PersonOutcome {
        let options: [INPerson] = candidates(of: person)
        switch SiriIntentPolicy.verdict(candidates: options.map(facts(of:))) {
        case .resolved(let index): return .success(options[index])
        case .ambiguous(let indexes): return .disambiguation(indexes.map { options[$0] })
        case .unresolved: return .success(person)
        }
    }

    static func personResult(_ outcome: PersonOutcome) -> INPersonResolutionResult {
        switch outcome {
        case .success(let person): return INPersonResolutionResult.success(with: person)
        case .disambiguation(let people): return INPersonResolutionResult.disambiguation(with: people)
        }
    }

    // MARK: - Resolve (INStartCallIntent)

    func resolveCallCapability(
        for intent: INStartCallIntent,
        with completion: @escaping (INStartCallCallCapabilityResolutionResult) -> Void
    ) {
        let capability: INCallCapability = intent.callCapability == .unknown ? .audioCall : intent.callCapability
        completion(INStartCallCallCapabilityResolutionResult(
            callCapabilityResolutionResult: INCallCapabilityResolutionResult.success(with: capability)))
    }

    /// What becomes of each person of a call request: all of them are passed on as they are.
    enum ContactOutcome {
        case needsValue
        case passThrough(INPerson)
    }

    static func contactOutcomes(for intent: INStartCallIntent) -> [ContactOutcome] {
        guard let contacts = intent.contacts, !contacts.isEmpty else { return [.needsValue] }
        return contacts.map { contactOutcome(for: $0) }
    }

    static func contactOutcome(for person: INPerson) -> ContactOutcome {
        .passThrough(person)
    }

    func resolveContacts(
        for intent: INStartCallIntent,
        with completion: @escaping ([INStartCallContactResolutionResult]) -> Void
    ) {
        completion(Self.contactOutcomes(for: intent).map { outcome -> INStartCallContactResolutionResult in
            switch outcome {
            case .needsValue:
                return INStartCallContactResolutionResult.needsValue()
            case .passThrough(let person):
                return INStartCallContactResolutionResult(
                    personResolutionResult: INPersonResolutionResult.success(with: person))
            }
        })
    }

    func resolveDestinationType(
        for intent: INStartCallIntent,
        with completion: @escaping (INCallDestinationTypeResolutionResult) -> Void
    ) {
        // Q-Audion is VoIP-only — every call is a "normal" destination, never
        // emergency/voicemail/redial in the PSTN sense those other cases model.
        completion(.success(with: .normal))
    }

    func resolveCallRecordToCallBack(
        for intent: INStartCallIntent,
        with completion: @escaping (INCallRecordResolutionResult) -> Void
    ) {
        // "Call back the last missed call" redialing is not implemented yet
        // (tracked as a known gap in the S1 plan, not silently dropped).
        completion(.notRequired())
    }

    // MARK: - Confirm / handle (INStartCallIntent)

    func confirm(intent: INStartCallIntent, completion: @escaping (INStartCallIntentResponse) -> Void) {
        guard let contacts = intent.contacts, !contacts.isEmpty else {
            completion(INStartCallIntentResponse(code: .failureRequiringAppLaunch, userActivity: nil))
            return
        }
        completion(INStartCallIntentResponse(code: .ready, userActivity: nil))
    }

    func handle(intent: INStartCallIntent, completion: @escaping (INStartCallIntentResponse) -> Void) {
        // SiriKit builds the NSUserActivity (carrying an INInteraction with
        // this intent + response) itself and hands it to the main app via
        // scene(_:continue:) / .onContinueUserActivity — this extension never
        // constructs that activity or touches CallKit directly.
        completion(INStartCallIntentResponse(code: .continueInApp, userActivity: nil))
    }
}

// MARK: - S2: INSendMessageIntent ("Hey Siri, invia un messaggio a X su Q-Audion")
//
// Queues to SiriMessageBridgeStore's outbox; NEVER encrypts or sends
// anything itself. Response code is deliberately `.inProgress` ("you are in
// the process of sending... but have not yet done so" — Apple's own doc),
// never `.success`: the real E2EE send only happens once the main app next
// drains the outbox (AppState), which may not be running right now.

extension IntentHandler: INSendMessageIntentHandling {

    /// What becomes of the recipients of a message request.
    enum RecipientsOutcome {
        /// A conversation names the peer; no recipient is needed.
        case notRequired
        /// Nobody was named.
        case needsValue
        /// One recipient.
        case person(PersonOutcome)
        /// Several recipients: one message goes to one person, so the user is asked to choose.
        case chooseOne([INPerson])
    }

    static func recipientsOutcome(for intent: INSendMessageIntent) -> RecipientsOutcome {
        if SiriIntentPolicy.conversationTarget(intent.conversationIdentifier) != nil { return .notRequired }
        guard let recipients = intent.recipients, !recipients.isEmpty else { return .needsValue }
        if recipients.count > 1 { return .chooseOne(recipients) }
        return .person(personOutcome(for: recipients[0]))
    }

    func resolveRecipients(
        for intent: INSendMessageIntent,
        with completion: @escaping ([INSendMessageRecipientResolutionResult]) -> Void
    ) {
        switch Self.recipientsOutcome(for: intent) {
        case .notRequired:
            completion([INSendMessageRecipientResolutionResult.notRequired()])
        case .needsValue:
            completion([INSendMessageRecipientResolutionResult.needsValue()])
        case .chooseOne(let recipients):
            completion([INSendMessageRecipientResolutionResult(
                personResolutionResult: INPersonResolutionResult.disambiguation(with: recipients))])
        case .person(let outcome):
            completion([INSendMessageRecipientResolutionResult(personResolutionResult: Self.personResult(outcome))])
        }
    }

    func resolveContent(
        for intent: INSendMessageIntent,
        with completion: @escaping (INStringResolutionResult) -> Void
    ) {
        if let text = SiriIntentPolicy.nonBlank(intent.content) {
            completion(INStringResolutionResult.success(with: text))
        } else {
            completion(INStringResolutionResult.needsValue())
        }
    }

    func confirm(intent: INSendMessageIntent, completion: @escaping (INSendMessageIntentResponse) -> Void) {
        guard SiriIntentPolicy.nonBlank(intent.content) != nil, Self.hasMessageTarget(intent) else {
            completion(INSendMessageIntentResponse(code: .failure, userActivity: nil))
            return
        }
        completion(INSendMessageIntentResponse(code: .ready, userActivity: nil))
    }

    func handle(intent: INSendMessageIntent, completion: @escaping (INSendMessageIntentResponse) -> Void) {
        guard let text = SiriIntentPolicy.nonBlank(intent.content), Self.hasMessageTarget(intent) else {
            completion(INSendMessageIntentResponse(code: .failure, userActivity: nil))
            return
        }
        let conversation = SiriIntentPolicy.conversationTarget(intent.conversationIdentifier)
        let person = intent.recipients?.first
        let outboxMessage = SiriMessageBridgeStore.OutboxMessage(
            handle: person?.personHandle?.value,
            spokenName: person?.displayName ?? "",
            text: text,
            conversationIdentifier: conversation,
            customIdentifier: person?.customIdentifier)
        store.enqueueOutboxMessage(outboxMessage)
        completion(INSendMessageIntentResponse(code: .inProgress, userActivity: nil))
    }

    /// A message needs either a conversation or exactly one recipient.
    static func hasMessageTarget(_ intent: INSendMessageIntent) -> Bool {
        switch recipientsOutcome(for: intent) {
        case .notRequired: return true
        case .person(.success): return true
        case .needsValue, .chooseOne, .person: return false
        }
    }
}

// MARK: - S2: INSearchForMessagesIntent ("Chiedi a Q-Audion di leggermi i messaggi di X")
//
// Read-only against SiriMessageBridgeStore's cache — a copy of recent
// plaintext the main app already decrypted through the real ratchet, opt-in
// via SiriMessagingConsent (default OFF). This extension never decrypts
// anything itself and never advances any ratchet state.

extension IntentHandler: INSearchForMessagesIntentHandling {

    func confirm(intent: INSearchForMessagesIntent, completion: @escaping (INSearchForMessagesIntentResponse) -> Void) {
        completion(INSearchForMessagesIntentResponse(code: .ready, userActivity: nil))
    }

    func handle(intent: INSearchForMessagesIntent, completion: @escaping (INSearchForMessagesIntentResponse) -> Void) {
        guard messagingConsent() else {
            // The user never opted into the plaintext-cache trade-off (see
            // SiriMessageBridgeStore.swift) — nothing to search here at all.
            completion(INSearchForMessagesIntentResponse(code: .failure, userActivity: nil))
            return
        }
        let named = intent.recipients?.first ?? intent.senders?.first
        let cached = store.recentMessages(peerUserId: nil, limit: 100)
        let matched = SiriIntentPolicy.matchMessages(
            cached,
            conversationIdentifiers: intent.conversationIdentifiers,
            messageIdentifiers: intent.identifiers,
            spokenName: named?.displayName,
            unreadOnly: intent.attributes.contains(.unread))

        let response = INSearchForMessagesIntentResponse(code: .success, userActivity: nil)
        response.messages = matched.suffix(10).map { msg in
            let senderPerson: INPerson? = msg.isOutgoing ? nil : INPerson(
                personHandle: INPersonHandle(value: msg.peerUserId, type: .unknown),
                nameComponents: nil,
                displayName: msg.peerDisplayName,
                image: nil,
                contactIdentifier: nil,
                customIdentifier: msg.peerUserId)
            return INMessage(
                identifier: SiriIntentPolicy.messageIdentifier(peerUserId: msg.peerUserId, sentAt: msg.sentAt),
                conversationIdentifier: msg.peerUserId,
                content: msg.text,
                dateSent: msg.sentAt,
                sender: senderPerson,
                recipients: nil,
                groupName: nil,
                messageType: .text,
                serviceName: "Q-Audion",
                audioMessageFile: nil)
        }
        completion(response)
    }
}

// MARK: - INSetMessageAttributeIntent (Siri marks what it has read aloud as read)
//
// Only "read" is supported. The request is queued like a sent message is: the
// conversation list lives in the main app, which applies the mark the next time
// it runs. The mark covers the messages Siri was given, up to the newest of
// them. Nothing is decrypted or changed here.

extension IntentHandler: INSetMessageAttributeIntentHandling {

    func resolveAttribute(
        for intent: INSetMessageAttributeIntent,
        with completion: @escaping (INMessageAttributeResolutionResult) -> Void
    ) {
        switch intent.attribute {
        case .read: completion(INMessageAttributeResolutionResult.success(with: .read))
        case .unknown: completion(INMessageAttributeResolutionResult.needsValue())
        default: completion(INMessageAttributeResolutionResult.unsupported())
        }
    }

    func confirm(
        intent: INSetMessageAttributeIntent,
        completion: @escaping (INSetMessageAttributeIntentResponse) -> Void
    ) {
        guard intent.attribute == .read else {
            completion(INSetMessageAttributeIntentResponse(code: .failureMessageAttributeNotSet, userActivity: nil))
            return
        }
        guard !SiriIntentPolicy.readTargets(inMessageIdentifiers: intent.identifiers).isEmpty else {
            completion(INSetMessageAttributeIntentResponse(code: .failureMessageNotFound, userActivity: nil))
            return
        }
        completion(INSetMessageAttributeIntentResponse(code: .ready, userActivity: nil))
    }

    func handle(
        intent: INSetMessageAttributeIntent,
        completion: @escaping (INSetMessageAttributeIntentResponse) -> Void
    ) {
        guard intent.attribute == .read else {
            completion(INSetMessageAttributeIntentResponse(code: .failureMessageAttributeNotSet, userActivity: nil))
            return
        }
        let targets = SiriIntentPolicy.readTargets(inMessageIdentifiers: intent.identifiers)
        guard !targets.isEmpty else {
            completion(INSetMessageAttributeIntentResponse(code: .failureMessageNotFound, userActivity: nil))
            return
        }
        for target in targets {
            store.enqueueReadMark(
                SiriMessageBridgeStore.ReadMark(peerUserId: target.peerUserId, upToSentAt: target.upToSentAt))
        }
        completion(INSetMessageAttributeIntentResponse(code: .success, userActivity: nil))
    }
}
