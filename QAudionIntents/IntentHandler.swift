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
/// **S2 (`INSendMessageIntent`/`INSearchForMessagesIntent`, see the
/// extensions at the bottom of this file) CANNOT be a pass-through** — per
/// Apple's own docs, `handle()` for both must send/search from inside this
/// process, there is no hand-off like calls get. Verified via a
/// `cryptography-security-expert` consultation (2026-09-06, recorded in the
/// plan doc): this extension NEVER touches this app's E2EE ratchet/session
/// material. It talks only to `SiriMessageBridgeStore`
/// (`QAudionApp/Siri/SiriMessageBridgeStore.swift`, compiled into this
/// target directly — see that file's header for the full security design)
/// — queuing outgoing text for the main app to actually encrypt+send later,
/// and reading an opt-in, main-app-populated plaintext cache for search.
///
/// This target still links no `QAudionEngine` at all — an Intents extension
/// runs under a tight, separate memory budget from the host app, the same
/// reason `QAudionBroadcastExtension` avoids linking the full engine
/// product (see that target's own `project.yml` comment).
final class IntentHandler: INExtension, INStartCallIntentHandling {

    override func handler(for intent: INIntent) -> Any {
        return self
    }

    // MARK: - Resolve

    func resolveCallCapability(
        for intent: INStartCallIntent,
        with completion: @escaping (INCallCapabilityResolutionResult) -> Void
    ) {
        let capability = intent.callCapability == .unknown ? .audioCall : intent.callCapability
        completion(.success(with: capability))
    }

    func resolveContacts(
        for intent: INStartCallIntent,
        with completion: @escaping ([INPersonResolutionResult]) -> Void
    ) {
        guard let contacts = intent.contacts, !contacts.isEmpty else {
            completion([INPersonResolutionResult.needsValue()])
            return
        }
        // Pass-through resolution only — whether this person is actually a
        // reachable Q-Audion contact is decided in-app, after handoff (see
        // AppState.handleSiriStartCall + SiriCallResolution). Rejecting here
        // would need this extension to read Q-Audion's own contact store,
        // which it deliberately does not link.
        completion(contacts.map { .success(with: $0) })
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

    // MARK: - Confirm / handle

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

    func resolveRecipients(
        for intent: INSendMessageIntent,
        with completion: @escaping ([INSendMessageRecipientResolutionResult]) -> Void
    ) {
        guard let recipients = intent.recipients, !recipients.isEmpty else {
            completion([INSendMessageRecipientResolutionResult.needsValue()])
            return
        }
        // Pass-through, same rationale as INStartCallIntent.resolveContacts
        // above — real Q-Audion contact resolution happens later, in the
        // main app's outbox drain (SiriCallResolution).
        completion(recipients.map { .success(with: $0) })
    }

    func confirm(intent: INSendMessageIntent, completion: @escaping (INSendMessageIntentResponse) -> Void) {
        guard let recipients = intent.recipients, !recipients.isEmpty,
              let content = intent.content, !content.isEmpty else {
            completion(INSendMessageIntentResponse(code: .failureRequiringAppLaunch, userActivity: nil))
            return
        }
        completion(INSendMessageIntentResponse(code: .ready, userActivity: nil))
    }

    func handle(intent: INSendMessageIntent, completion: @escaping (INSendMessageIntentResponse) -> Void) {
        guard let person = intent.recipients?.first, let text = intent.content, !text.isEmpty else {
            completion(INSendMessageIntentResponse(code: .failure, userActivity: nil))
            return
        }
        let outboxMessage = SiriMessageBridgeStore.OutboxMessage(
            handle: person.personHandle?.value,
            spokenName: person.displayName,
            text: text)
        SiriMessageBridgeStore.shared.enqueueOutboxMessage(outboxMessage)
        completion(INSendMessageIntentResponse(code: .inProgress, userActivity: nil))
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
        guard SiriMessagingConsent.isEnabled else {
            // The user never opted into the plaintext-cache trade-off (see
            // SiriMessageBridgeStore.swift) — nothing to search here at all.
            completion(INSearchForMessagesIntentResponse(code: .failureRequiringAppLaunch, userActivity: nil))
            return
        }
        let named = intent.recipients?.first ?? intent.senders?.first
        let spokenName = named?.displayName.trimmingCharacters(in: .whitespacesAndNewlines)

        let cached = SiriMessageBridgeStore.shared.recentMessages(limit: 100)
        let matched: [SiriMessageBridgeStore.CachedMessage]
        if let spokenName, !spokenName.isEmpty {
            matched = cached.filter { $0.peerDisplayName.localizedCaseInsensitiveCompare(spokenName) == .orderedSame }
        } else {
            matched = cached
        }

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
                identifier: "\(msg.peerUserId)-\(Int(msg.sentAt.timeIntervalSince1970))",
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
