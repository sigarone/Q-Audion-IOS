import XCTest
import Intents
import ObjectiveC

/// The Siri Intents extension (`QAudionIntents/IntentHandler.swift`) driven with real SiriKit objects: who counts as a
/// person (a name Siri only heard is passed on to the app), how a conversation identifier from the car is honoured,
/// what a message request queues, what a search returns, the consent of the app, and the read mark Siri sends after
/// it has read messages aloud.
///
/// The extension's source is compiled into the test bundle itself (see `QAudionApp/project-apptests.yml`), with a fake
/// bridge in place of the App Group container.
///
/// One test asks the handler whether it answers to the Objective-C selector of every resolve, confirm and handle method
/// of the intents it handles. A method whose Swift signature only nearly matches the protocol's is silently never
/// called by SiriKit; that is how a resolver written against the wrong result type can sit in the code unnoticed.
///
/// Wired into CI: on the include list of `QAudionApp/project-apptests.yml` and in the `-only-testing` list of
/// `.github/workflows/ios-app-tests.yml`.
final class IntentHandlerTests: XCTestCase {

    // MARK: - fakes and fixtures

    private final class FakeBridge: SiriBridgeStoring {
        var outbox: [SiriMessageBridgeStore.OutboxMessage] = []
        var readMarks: [SiriMessageBridgeStore.ReadMark] = []
        var cache: [SiriMessageBridgeStore.CachedMessage] = []

        func enqueueOutboxMessage(_ message: SiriMessageBridgeStore.OutboxMessage) { outbox.append(message) }
        func enqueueReadMark(_ mark: SiriMessageBridgeStore.ReadMark) { readMarks.append(mark) }
        func recentMessages(peerUserId: String?, limit: Int) -> [SiriMessageBridgeStore.CachedMessage] {
            let filtered = peerUserId.map { id in cache.filter { $0.peerUserId == id } } ?? cache
            return Array(filtered.suffix(limit))
        }
    }

    private var bridge = FakeBridge()
    private var consent = true

    private func makeHandler() -> IntentHandler {
        IntentHandler(store: bridge, messagingConsent: { [unowned self] in self.consent })
    }

    override func setUp() {
        super.setUp()
        bridge = FakeBridge()
        consent = true
    }

    private func person(_ name: String, phone: String? = nil, custom: String? = nil) -> INPerson {
        INPerson(
            personHandle: INPersonHandle(value: phone, type: phone == nil ? .unknown : .phoneNumber),
            nameComponents: nil, displayName: name, image: nil, contactIdentifier: nil, customIdentifier: custom)
    }

    private func describe(_ outcome: IntentHandler.PersonOutcome) -> String {
        switch outcome {
        case .success(let p): return "success:\(p.displayName)"
        case .disambiguation(let ps): return "disambiguation:" + ps.map { $0.displayName }.joined(separator: ",")
        }
    }

    private func callIntent(_ people: [INPerson]?) -> INStartCallIntent {
        INStartCallIntent(
            callRecordFilter: nil, callRecordToCallBack: nil, audioRoute: .unknown, destinationType: .normal,
            contacts: people, callCapability: .audioCall)
    }

    private func sendIntent(_ recipients: [INPerson]?, text: String? = "ciao", conversation: String? = nil) -> INSendMessageIntent {
        INSendMessageIntent(
            recipients: recipients, outgoingMessageType: .outgoingMessageText, content: text,
            speakableGroupName: nil, conversationIdentifier: conversation, serviceName: nil, sender: nil,
            attachments: nil)
    }

    private func searchIntent(conversations: [String]? = nil, unread: Bool = false, names: [INPerson]? = nil)
        -> INSearchForMessagesIntent
    {
        INSearchForMessagesIntent(
            recipients: nil, senders: names, searchTerms: nil, attributes: unread ? [.unread] : [],
            dateTime: nil, identifiers: nil, notificationIdentifiers: nil, speakableGroupNames: nil,
            conversationIdentifiers: conversations)
    }

    // MARK: - SiriKit really calls what is written

    func test_theHandlerAnswersToEverySelectorSiriKitUses() {
        let handler = makeHandler()
        let selectors: [(String, Selector)] = [
            ("call: capability", #selector(INStartCallIntentHandling.resolveCallCapability(for:with:))),
            ("call: contacts", #selector(INStartCallIntentHandling.resolveContacts(for:with:))),
            ("call: destination", #selector(INStartCallIntentHandling.resolveDestinationType(for:with:))),
            ("call: call record", #selector(INStartCallIntentHandling.resolveCallRecordToCallBack(for:with:))),
            ("call: confirm", #selector(INStartCallIntentHandling.confirm(intent:completion:))),
            ("call: handle", #selector(INStartCallIntentHandling.handle(intent:completion:))),
            ("send: content", #selector(INSendMessageIntentHandling.resolveContent(for:with:))),
            ("send: confirm", #selector(INSendMessageIntentHandling.confirm(intent:completion:))),
            ("send: handle", #selector(INSendMessageIntentHandling.handle(intent:completion:))),
            ("search: confirm", #selector(INSearchForMessagesIntentHandling.confirm(intent:completion:))),
            ("search: handle", #selector(INSearchForMessagesIntentHandling.handle(intent:completion:))),
            ("attribute: attribute", #selector(INSetMessageAttributeIntentHandling.resolveAttribute(for:with:))),
            ("attribute: confirm", #selector(INSetMessageAttributeIntentHandling.confirm(intent:completion:))),
            ("attribute: handle", #selector(INSetMessageAttributeIntentHandling.handle(intent:completion:))),
        ]
        for (name, selector) in selectors {
            XCTAssertTrue(handler.responds(to: selector), "SiriKit would never call \(name): \(selector)")
        }
        // The recipients resolver exists with two result types (the earlier one is deprecated), so its selector is
        // looked up among the methods the Objective-C runtime has for the class.
        XCTAssertTrue(objcSelectorNames(of: IntentHandler.self).contains { $0.hasPrefix("resolveRecipientsForSendMessage:") },
                      "SiriKit would never call the recipients resolver")
    }

    /// The names of the Objective-C methods a class exposes: what SiriKit can call.
    private func objcSelectorNames(of type: AnyClass) -> [String] {
        var count: UInt32 = 0
        guard let list = class_copyMethodList(type, &count) else { return [] }
        defer { free(list) }
        return (0..<Int(count)).map { NSStringFromSelector(method_getName(list[$0])) }
    }

    func test_theHandlerHandlesTheFourIntentsOfAMessagingAndCallingApp() {
        let handler: Any = makeHandler()
        XCTAssertTrue(handler is INStartCallIntentHandling)
        XCTAssertTrue(handler is INSendMessageIntentHandling)
        XCTAssertTrue(handler is INSearchForMessagesIntentHandling)
        XCTAssertTrue(handler is INSetMessageAttributeIntentHandling)
    }

    // MARK: - calls

    func test_aCallWithNobodyNamedAsksForAValue() {
        let outcomes = IntentHandler.contactOutcomes(for: callIntent(nil))
        XCTAssertEqual(outcomes.count, 1)
        guard case .needsValue = outcomes[0] else { return XCTFail("expected needsValue, got \(outcomes[0])") }
    }

    /// The person a call outcome passes on; nil for any other outcome.
    private func passedOn(_ outcome: IntentHandler.ContactOutcome) -> INPerson? {
        guard case .passThrough(let person) = outcome else { return nil }
        return person
    }

    /// What identifies a person. An intent keeps a copy of the people it is given, so a person that went through
    /// one is compared by these and not by identity.
    private func facts(_ person: INPerson?) -> [String?] {
        [person?.displayName, person?.personHandle?.value, person?.customIdentifier]
    }

    func test_aPersonTiedToAContactCardIsPassedOnAsItIs() {
        let anna = person("Anna", phone: "+390212345678")
        let outcomes = IntentHandler.contactOutcomes(for: callIntent([anna]))
        XCTAssertEqual(outcomes.count, 1)
        XCTAssertEqual(facts(passedOn(outcomes[0])), facts(anna))
    }

    func test_aPersonThisAppDonatedIsPassedOnAsItIs() {
        let anna = person("Anna", custom: "peer-1")
        let outcomes = IntentHandler.contactOutcomes(for: callIntent([anna]))
        XCTAssertEqual(outcomes.count, 1)
        XCTAssertEqual(facts(passedOn(outcomes[0])), facts(anna))
    }

    func test_aNameSiriOnlyHeardIsPassedOnToTheApp() {
        let mario = person("Mario")
        let outcomes = IntentHandler.contactOutcomes(for: callIntent([mario]))
        XCTAssertEqual(outcomes.count, 1)
        XCTAssertEqual(facts(passedOn(outcomes[0])), facts(mario))
    }

    func test_everyPersonOfOneCallIsPassedOnAsItIs() {
        let anna = person("Anna", phone: "+1")
        let luca = person("Luca", phone: "+2")
        let outcomes = IntentHandler.contactOutcomes(for: callIntent([anna, luca]))
        XCTAssertEqual(outcomes.count, 2)
        XCTAssertEqual(facts(passedOn(outcomes[0])), facts(anna))
        XCTAssertEqual(facts(passedOn(outcomes[1])), facts(luca))
    }

    /// A person Siri tied to candidates (`siriMatches`), which an `INPerson` made by hand cannot carry.
    private final class MatchedPerson: INPerson {
        var matches: [INPerson] = []
        override var siriMatches: [INPerson]? { matches }
    }

    private func matchedPerson(_ matches: [INPerson]) -> MatchedPerson {
        let heard = MatchedPerson(
            personHandle: INPersonHandle(value: nil, type: .unknown), nameComponents: nil, displayName: "Anna",
            image: nil, contactIdentifier: nil, customIdentifier: nil)
        heard.matches = matches
        return heard
    }

    func test_aPersonWithSeveralSiriMatchesIsPassedOnAsItIsNotTurnedIntoAChoice() {
        let heard = matchedPerson([person("Anna R", phone: "+1", custom: "peer-1"), person("Anna V", phone: "+2", custom: "peer-2")])
        XCTAssertTrue(passedOn(IntentHandler.contactOutcome(for: heard)) === heard)
    }

    func test_aPersonWithOneSiriMatchIsPassedOnNotReplacedByTheMatch() {
        let heard = matchedPerson([person("Anna Rossi", phone: "+1", custom: "peer-1")])
        XCTAssertTrue(passedOn(IntentHandler.contactOutcome(for: heard)) === heard)
    }

    func test_resolveContactsAnswersOnceForEachPerson() {
        // The completion is @Sendable; the handler answers on the calling thread, so the capture is safe.
        nonisolated(unsafe) var answered: [Int] = []
        makeHandler().resolveContacts(for: callIntent([person("Anna", phone: "+1"), person("Luca")])) { answered.append($0.count) }
        XCTAssertEqual(answered, [2])
        nonisolated(unsafe) var empty: [Int] = []
        makeHandler().resolveContacts(for: callIntent([])) { empty.append($0.count) }
        XCTAssertEqual(empty, [1])
    }

    func test_aCallToANameSiriOnlyHeardIsConfirmedAndHandedToTheApp() {
        var codes: [INStartCallIntentResponseCode] = []
        makeHandler().confirm(intent: callIntent([person("Mario")])) { codes.append($0.code) }
        makeHandler().confirm(intent: callIntent(nil)) { codes.append($0.code) }
        makeHandler().confirm(intent: callIntent([person("Anna", phone: "+1")])) { codes.append($0.code) }
        XCTAssertEqual(codes, [.ready, .failureRequiringAppLaunch, .ready])
        var handled: [INStartCallIntentResponseCode] = []
        makeHandler().handle(intent: callIntent([person("Mario")])) { handled.append($0.code) }
        XCTAssertEqual(handled, [.continueInApp])
    }

    func test_aResolvedCallContinuesInTheApp() {
        var codes: [INStartCallIntentResponseCode] = []
        makeHandler().handle(intent: callIntent([person("Anna", phone: "+1")])) { codes.append($0.code) }
        XCTAssertEqual(codes, [.continueInApp])
    }

    // MARK: - messages: who they go to

    func test_aConversationFromTheCarNamesThePeerAndNeedsNoRecipient() {
        let outcome = IntentHandler.recipientsOutcome(for: sendIntent(nil, conversation: "peer-1"))
        guard case .notRequired = outcome else { return XCTFail("expected notRequired, got \(outcome)") }
    }

    func test_aBlankConversationIdentifierIsNoConversation() {
        let outcome = IntentHandler.recipientsOutcome(for: sendIntent(nil, conversation: "   "))
        guard case .needsValue = outcome else { return XCTFail("expected needsValue, got \(outcome)") }
    }

    func test_aRecipientSiriOnlyHeardIsPassedOnLikeOneItTiedToSomebody() {
        let named = IntentHandler.recipientsOutcome(for: sendIntent([person("Mario")]))
        guard case .person(let namedOutcome) = named else { return XCTFail("expected a person") }
        XCTAssertEqual(describe(namedOutcome), "success:Mario")

        let tied = IntentHandler.recipientsOutcome(for: sendIntent([person("Anna", phone: "+39")]))
        guard case .person(let tiedOutcome) = tied else { return XCTFail("expected a person") }
        XCTAssertEqual(describe(tiedOutcome), "success:Anna")
    }

    func test_severalRecipientsAreAChoiceBecauseAMessageGoesToOnePerson() {
        let outcome = IntentHandler.recipientsOutcome(for: sendIntent([person("A", phone: "+1"), person("B", phone: "+2")]))
        guard case .chooseOne(let people) = outcome else { return XCTFail("expected chooseOne, got \(outcome)") }
        XCTAssertEqual(people.map { $0.displayName }, ["A", "B"])
    }

    // MARK: - messages: what is queued

    func test_aMessageToAConversationQueuesTheConversationIdentifier() {
        var codes: [INSendMessageIntentResponseCode] = []
        makeHandler().handle(intent: sendIntent(nil, text: "  ci vediamo alle 8  ", conversation: "peer-1")) { codes.append($0.code) }
        XCTAssertEqual(codes, [.inProgress])
        XCTAssertEqual(bridge.outbox.count, 1)
        XCTAssertEqual(bridge.outbox.first?.conversationIdentifier, "peer-1")
        XCTAssertEqual(bridge.outbox.first?.text, "ci vediamo alle 8")
        XCTAssertEqual(bridge.outbox.first?.spokenName, "")
    }

    func test_aMessageToAPersonQueuesTheHandleTheNameAndTheIdentifier() {
        var codes: [INSendMessageIntentResponseCode] = []
        makeHandler().handle(intent: sendIntent([person("Anna", phone: "+390212345678", custom: "peer-1")])) { codes.append($0.code) }
        XCTAssertEqual(codes, [.inProgress])
        XCTAssertEqual(bridge.outbox.first?.handle, "+390212345678")
        XCTAssertEqual(bridge.outbox.first?.spokenName, "Anna")
        XCTAssertEqual(bridge.outbox.first?.customIdentifier, "peer-1")
        XCTAssertNil(bridge.outbox.first?.conversationIdentifier)
    }

    func test_aMessageToANameSiriOnlyHeardIsQueuedWithTheNameForTheAppToMatch() {
        var codes: [INSendMessageIntentResponseCode] = []
        makeHandler().handle(intent: sendIntent([person("Mario")])) { codes.append($0.code) }
        XCTAssertEqual(codes, [.inProgress])
        XCTAssertEqual(bridge.outbox.count, 1)
        XCTAssertEqual(bridge.outbox.first?.spokenName, "Mario")
        XCTAssertNil(bridge.outbox.first?.handle)
        XCTAssertNil(bridge.outbox.first?.customIdentifier)
        XCTAssertNil(bridge.outbox.first?.conversationIdentifier)
    }

    func test_aMessageWithNoRecipientAndNoConversationIsNotQueued() {
        var codes: [INSendMessageIntentResponseCode] = []
        makeHandler().handle(intent: sendIntent(nil)) { codes.append($0.code) }
        XCTAssertEqual(codes, [.failure])
        XCTAssertTrue(bridge.outbox.isEmpty)
    }

    func test_aMessageWithoutTextIsNotQueued() {
        var codes: [INSendMessageIntentResponseCode] = []
        makeHandler().handle(intent: sendIntent(nil, text: "   ", conversation: "peer-1")) { codes.append($0.code) }
        makeHandler().handle(intent: sendIntent(nil, text: nil, conversation: "peer-1")) { codes.append($0.code) }
        XCTAssertEqual(codes, [.failure, .failure])
        XCTAssertTrue(bridge.outbox.isEmpty)
    }

    func test_aMessageToSeveralPeopleIsNotQueuedForTheFirstOfThem() {
        var codes: [INSendMessageIntentResponseCode] = []
        makeHandler().handle(intent: sendIntent([person("A", phone: "+1"), person("B", phone: "+2")])) { codes.append($0.code) }
        XCTAssertEqual(codes, [.failure])
        XCTAssertTrue(bridge.outbox.isEmpty)
    }

    func test_confirmingAMessageNeedsTextAndATarget() {
        var codes: [INSendMessageIntentResponseCode] = []
        makeHandler().confirm(intent: sendIntent(nil, conversation: "peer-1")) { codes.append($0.code) }
        makeHandler().confirm(intent: sendIntent(nil, conversation: nil)) { codes.append($0.code) }
        makeHandler().confirm(intent: sendIntent(nil, text: "", conversation: "peer-1")) { codes.append($0.code) }
        XCTAssertEqual(codes, [.ready, .failure, .failure])
    }

    // MARK: - search

    private func cached(_ peer: String, _ name: String, _ text: String, at seconds: TimeInterval, unread: Bool?)
        -> SiriMessageBridgeStore.CachedMessage
    {
        SiriMessageBridgeStore.CachedMessage(
            peerUserId: peer, peerDisplayName: name, text: text, sentAt: Date(timeIntervalSince1970: seconds),
            isOutgoing: false, isUnread: unread)
    }

    private func fillCache() {
        bridge.cache = [
            cached("p1", "Anna", "one", at: 100, unread: true),
            cached("p2", "Luca", "two", at: 200, unread: false),
            cached("p1", "Anna", "three", at: 300, unread: false),
        ]
    }

    func test_aSearchWithoutConsentFailsAndReadsNothing() {
        fillCache()
        consent = false
        var codes: [INSearchForMessagesIntentResponseCode] = []
        makeHandler().handle(intent: searchIntent(conversations: ["p1"])) { codes.append($0.code) }
        XCTAssertEqual(codes, [.failure])
    }

    // MARK: - the consent of the app, through the extension's own initializer

    private final class CountingBridge: SiriBridgeStoring {
        var reads = 0
        var cache: [SiriMessageBridgeStore.CachedMessage] = []
        func enqueueOutboxMessage(_ message: SiriMessageBridgeStore.OutboxMessage) {}
        func enqueueReadMark(_ mark: SiriMessageBridgeStore.ReadMark) {}
        func recentMessages(peerUserId: String?, limit: Int) -> [SiriMessageBridgeStore.CachedMessage] {
            reads += 1
            return cache
        }
    }

    /// Runs `body` with the opt-in setting of the app at `value` and `IntentHandler()` (the extension's own
    /// initializer) reading `counting`, then puts both back.
    private func withExtensionInitializer(consent value: Bool, bridge counting: CountingBridge, _ body: (IntentHandler) -> Void) {
        let previousConsent = SiriMessagingConsent.isEnabled
        let previousStore = IntentHandler.productionStore
        SiriMessagingConsent.setEnabled(value)
        IntentHandler.productionStore = { counting }
        defer {
            SiriMessagingConsent.setEnabled(previousConsent)
            IntentHandler.productionStore = previousStore
        }
        body(IntentHandler())
    }

    func test_theExtensionsOwnInitializerAnswersASearchWithoutConsentWithNothingAndReadsNothing() {
        let counting = CountingBridge()
        counting.cache = [cached("p1", "Anna", "one", at: 100, unread: true)]
        var responses: [INSearchForMessagesIntentResponse] = []
        withExtensionInitializer(consent: false, bridge: counting) { handler in
            handler.handle(intent: searchIntent(conversations: ["p1"])) { responses.append($0) }
        }
        XCTAssertEqual(responses.count, 1)
        XCTAssertEqual(responses.first?.code, .failure)
        XCTAssertTrue(responses.first?.messages?.isEmpty ?? true)
        XCTAssertEqual(counting.reads, 0)
    }

    func test_theExtensionsOwnInitializerReadsTheBridgeWhenTheAppSettingIsOn() throws {
        let counting = CountingBridge()
        counting.cache = [cached("p1", "Anna", "one", at: 100, unread: true)]
        var responses: [INSearchForMessagesIntentResponse] = []
        var settingTookEffect = false
        withExtensionInitializer(consent: true, bridge: counting) { handler in
            settingTookEffect = SiriMessagingConsent.isEnabled
            guard settingTookEffect else { return }
            handler.handle(intent: searchIntent(conversations: ["p1"])) { responses.append($0) }
        }
        try XCTSkipUnless(settingTookEffect, "the App Group defaults are not available to this test host")
        XCTAssertEqual(responses.first?.code, .success)
        XCTAssertEqual(responses.first?.messages?.map { $0.content ?? "" }, ["one"])
        XCTAssertEqual(counting.reads, 1)
    }

    func test_aSearchHonoursTheConversationIdentifierOfTheCar() {
        fillCache()
        var responses: [INSearchForMessagesIntentResponse] = []
        makeHandler().handle(intent: searchIntent(conversations: ["p1"])) { responses.append($0) }
        XCTAssertEqual(responses.first?.code, .success)
        XCTAssertEqual(responses.first?.messages?.map { $0.content ?? "" }, ["one", "three"])
        XCTAssertEqual(Set(responses.first?.messages?.compactMap { $0.conversationIdentifier } ?? []), ["p1"])
    }

    func test_theMessageIdentifiersAreTheOnesTheReadMarkUnderstands() {
        fillCache()
        var responses: [INSearchForMessagesIntentResponse] = []
        makeHandler().handle(intent: searchIntent(conversations: ["p2"])) { responses.append($0) }
        let identifier = responses.first?.messages?.first?.identifier ?? ""
        XCTAssertEqual(SiriIntentPolicy.peerUserId(inMessageIdentifier: identifier), "p2")
    }

    func test_aSearchForNewMessagesReturnsTheUnreadOnes() {
        fillCache()
        var responses: [INSearchForMessagesIntentResponse] = []
        makeHandler().handle(intent: searchIntent(unread: true)) { responses.append($0) }
        XCTAssertEqual(responses.first?.messages?.map { $0.content ?? "" }, ["one"])
    }

    func test_aSearchByNameStillWorksWhenNoConversationIsNamed() {
        fillCache()
        var responses: [INSearchForMessagesIntentResponse] = []
        makeHandler().handle(intent: searchIntent(names: [person("luca")])) { responses.append($0) }
        XCTAssertEqual(responses.first?.messages?.map { $0.content ?? "" }, ["two"])
    }

    // MARK: - marking as read

    private func attributeIntent(_ ids: [String]?, _ attribute: INMessageAttribute = .read) -> INSetMessageAttributeIntent {
        INSetMessageAttributeIntent(identifiers: ids, attribute: attribute)
    }

    func test_readingAloudQueuesOneReadMarkForEachConversationUpToTheNewestMessageGiven() {
        var codes: [INSetMessageAttributeIntentResponseCode] = []
        makeHandler().handle(intent: attributeIntent(["p1#100", "p2#200", "p1#300"])) { codes.append($0.code) }
        XCTAssertEqual(codes, [.success])
        XCTAssertEqual(bridge.readMarks.map { $0.peerUserId }, ["p1", "p2"])
        XCTAssertEqual(bridge.readMarks.map { $0.upToSentAt }, [300, 200])
    }

    func test_onlyReadIsSupported() {
        var codes: [INSetMessageAttributeIntentResponseCode] = []
        makeHandler().handle(intent: attributeIntent(["p1#100"], .unread)) { codes.append($0.code) }
        makeHandler().handle(intent: attributeIntent(["p1#100"], .flagged)) { codes.append($0.code) }
        XCTAssertEqual(codes, [.failureMessageAttributeNotSet, .failureMessageAttributeNotSet])
        XCTAssertTrue(bridge.readMarks.isEmpty)
    }

    func test_identifiersThatAreNotOursMarkNothing() {
        var codes: [INSetMessageAttributeIntentResponseCode] = []
        makeHandler().handle(intent: attributeIntent(["junk", ""])) { codes.append($0.code) }
        makeHandler().handle(intent: attributeIntent(nil)) { codes.append($0.code) }
        XCTAssertEqual(codes, [.failureMessageNotFound, .failureMessageNotFound])
        XCTAssertTrue(bridge.readMarks.isEmpty)
    }

    func test_confirmingAReadMarkNeedsAMessageOfOurs() {
        var codes: [INSetMessageAttributeIntentResponseCode] = []
        makeHandler().confirm(intent: attributeIntent(["p1#100"])) { codes.append($0.code) }
        makeHandler().confirm(intent: attributeIntent(["junk"])) { codes.append($0.code) }
        makeHandler().confirm(intent: attributeIntent(["p1#100"], .unread)) { codes.append($0.code) }
        XCTAssertEqual(codes, [.ready, .failureMessageNotFound, .failureMessageAttributeNotSet])
    }
}
