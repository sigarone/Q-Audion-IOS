import XCTest

/// The decisions of the Siri Intents extension that need no SiriKit (`QAudionApp/Siri/SiriIntentPolicy.swift`): which
/// persons count as somebody, how a message is named when Siri gives it back, which cached messages a search returns,
/// and which of them are unread.
///
/// The file under test is compiled into the test bundle itself (the bundle lists it as a source in
/// `QAudionApp/project-apptests.yml`, next to `QAudionIntents/IntentHandler.swift`), which is also how the extension
/// compiles it.
///
/// Wired into CI: on the include list of `QAudionApp/project-apptests.yml` and in the `-only-testing` list of
/// `.github/workflows/ios-app-tests.yml`.
final class SiriIntentPolicyTests: XCTestCase {

    private func person(_ name: String = "Mario", handle: String? = nil, custom: String? = nil) -> SiriPersonFacts {
        SiriPersonFacts(displayName: name, handle: handle, customIdentifier: custom)
    }

    // MARK: - people

    func test_aBareNameIsNotSomebody() {
        XCTAssertFalse(person("Mario").hasIdentity)
        XCTAssertFalse(person("Mario", handle: "", custom: "  ").hasIdentity)
        XCTAssertEqual(SiriIntentPolicy.verdict(candidates: [person("Mario")]), .unresolved)
    }

    func test_aHandleOrAnIdentifierIsEnough() {
        XCTAssertTrue(person(handle: "+390212345678").hasIdentity)
        XCTAssertTrue(person(custom: "peer-1").hasIdentity)
        XCTAssertEqual(SiriIntentPolicy.verdict(candidates: [person(handle: "+390212345678")]), .resolved(0))
        XCTAssertEqual(SiriIntentPolicy.verdict(candidates: [person(custom: "peer-1")]), .resolved(0))
    }

    func test_noCandidatesIsNobody() {
        XCTAssertEqual(SiriIntentPolicy.verdict(candidates: []), .unresolved)
    }

    func test_severalCandidatesThatAreSomebodyAreAskedAbout() {
        let candidates = [person("A", handle: "+1"), person("B"), person("C", handle: "+3")]
        XCTAssertEqual(SiriIntentPolicy.verdict(candidates: candidates), .ambiguous([0, 2]))
    }

    func test_oneCandidateThatIsSomebodyAmongNamesIsTheAnswer() {
        let candidates = [person("A"), person("B", handle: "+2"), person("C")]
        XCTAssertEqual(SiriIntentPolicy.verdict(candidates: candidates), .resolved(1))
    }

    // MARK: - conversations

    func test_aConversationTargetIsTrimmedAndNeverBlank() {
        XCTAssertEqual(SiriIntentPolicy.conversationTarget(" peer-1 "), "peer-1")
        XCTAssertNil(SiriIntentPolicy.conversationTarget(nil))
        XCTAssertNil(SiriIntentPolicy.conversationTarget(""))
        XCTAssertNil(SiriIntentPolicy.conversationTarget("   \n"))
        XCTAssertEqual(SiriIntentPolicy.conversationTargets([" a ", "", "b", "  "]), ["a", "b"])
        XCTAssertEqual(SiriIntentPolicy.conversationTargets(nil), [])
    }

    // MARK: - message identifiers

    func test_aMessageIdentifierNamesItsPeerEvenWhenThePeerIdHasDashes() {
        let id = SiriIntentPolicy.messageIdentifier(
            peerUserId: "0f8fad5b-d9cb-469f-a165-70867728950e", sentAt: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(id, "0f8fad5b-d9cb-469f-a165-70867728950e#1700000000")
        XCTAssertEqual(SiriIntentPolicy.peerUserId(inMessageIdentifier: id), "0f8fad5b-d9cb-469f-a165-70867728950e")
    }

    func test_anIdentifierThatIsNotOursNamesNobody() {
        XCTAssertNil(SiriIntentPolicy.peerUserId(inMessageIdentifier: "no-separator"))
        XCTAssertNil(SiriIntentPolicy.peerUserId(inMessageIdentifier: "#123"))
        XCTAssertNil(SiriIntentPolicy.peerUserId(inMessageIdentifier: "peer#"))
        XCTAssertNil(SiriIntentPolicy.peerUserId(inMessageIdentifier: "peer#12a"))
        XCTAssertNil(SiriIntentPolicy.peerUserId(inMessageIdentifier: ""))
    }

    func test_aMessageIdentifierIsTakenApartIntoPeerAndSeconds() {
        let parsed = SiriIntentPolicy.parse(messageIdentifier: "a#b#42")
        XCTAssertEqual(parsed?.peerUserId, "a#b")
        XCTAssertEqual(parsed?.sentAt, 42)
        XCTAssertNil(SiriIntentPolicy.parse(messageIdentifier: "peer#99999999999999999999999"))
    }

    func test_theReadTargetsOfSeveralIdentifiersAreDistinctInOrderAndCarryTheNewestMessage() {
        let targets = SiriIntentPolicy.readTargets(inMessageIdentifiers: ["b#1", "a#2", "b#30", "junk", "c#4", "b#9"])
        XCTAssertEqual(targets, [
            SiriReadTarget(peerUserId: "b", upToSentAt: 30),
            SiriReadTarget(peerUserId: "a", upToSentAt: 2),
            SiriReadTarget(peerUserId: "c", upToSentAt: 4),
        ])
        XCTAssertEqual(SiriIntentPolicy.readTargets(inMessageIdentifiers: nil), [])
    }

    func test_queuedReadMarksOfOnePeerAreFoldedIntoTheNewestBound() {
        let marks = [
            SiriMessageBridgeStore.ReadMark(peerUserId: "a", upToSentAt: 10),
            SiriMessageBridgeStore.ReadMark(peerUserId: "b", upToSentAt: 5),
            SiriMessageBridgeStore.ReadMark(peerUserId: "a", upToSentAt: 40),
            SiriMessageBridgeStore.ReadMark(peerUserId: "a", upToSentAt: 20),
        ]
        let merged = SiriIntentPolicy.mergedReadMarks(marks)
        XCTAssertEqual(merged.map { $0.peerUserId }, ["a", "b"])
        XCTAssertEqual(merged.map { $0.upToSentAt }, [40, 5])
    }

    // MARK: - unread

    func test_theLastIncomingMessagesAreTheUnreadOnes() {
        // oldest first: in, out, in, in, out
        let flags = SiriIntentPolicy.unreadFlags(isIncoming: [true, false, true, true, false], unreadCount: 2)
        XCTAssertEqual(flags, [false, false, true, true, false])
    }

    func test_nothingIsUnreadWithoutAnUnreadCount() {
        XCTAssertEqual(SiriIntentPolicy.unreadFlags(isIncoming: [true, true], unreadCount: 0), [false, false])
        XCTAssertEqual(SiriIntentPolicy.unreadFlags(isIncoming: [true, true], unreadCount: -3), [false, false])
        XCTAssertEqual(SiriIntentPolicy.unreadFlags(isIncoming: [], unreadCount: 5), [])
    }

    func test_messagesAfterTheBoundSiriWasGivenStayUnread() {
        // oldest first: in 100, in 200, out 250, in 300, in 400; four unread, Siri was given up to 200
        let left = SiriIntentPolicy.unreadCountAfterRead(
            isIncoming: [true, true, false, true, true], sentAt: [100, 200, 250, 300, 400], unreadCount: 4,
            upToSentAt: 200)
        XCTAssertEqual(left, 2)
    }

    func test_aBoundAtOrAfterTheNewestMessageLeavesNothingUnread() {
        let left = SiriIntentPolicy.unreadCountAfterRead(
            isIncoming: [true, true], sentAt: [100, 200], unreadCount: 2, upToSentAt: 200)
        XCTAssertEqual(left, 0)
    }

    func test_aBoundBeforeEverythingLeavesTheUnreadCountAsItWas() {
        let left = SiriIntentPolicy.unreadCountAfterRead(
            isIncoming: [true, true, true], sentAt: [100, 200, 300], unreadCount: 2, upToSentAt: 50)
        XCTAssertEqual(left, 2)
    }

    func test_moreUnreadThanIncomingMarksEveryIncomingOneAndNeverAnOutgoingOne() {
        let flags = SiriIntentPolicy.unreadFlags(isIncoming: [false, true, false, true], unreadCount: 9)
        XCTAssertEqual(flags, [false, true, false, true])
    }

    // MARK: - searching the cache

    private func message(_ peer: String, _ name: String, _ text: String, at seconds: TimeInterval,
                         outgoing: Bool = false, unread: Bool? = nil) -> SiriMessageBridgeStore.CachedMessage {
        SiriMessageBridgeStore.CachedMessage(
            peerUserId: peer, peerDisplayName: name, text: text, sentAt: Date(timeIntervalSince1970: seconds),
            isOutgoing: outgoing, isUnread: unread)
    }

    private var cache: [SiriMessageBridgeStore.CachedMessage] {
        [message("p1", "Anna", "one", at: 100, unread: true),
         message("p2", "Luca", "two", at: 200, unread: false),
         message("p1", "Anna", "three", at: 300, outgoing: true),
         message("p3", "anna", "four", at: 400, unread: true)]
    }

    private func texts(_ list: [SiriMessageBridgeStore.CachedMessage]) -> [String] { list.map { $0.text } }

    func test_withoutAnyCriterionEverythingIsReturned() {
        let all = SiriIntentPolicy.matchMessages(
            cache, conversationIdentifiers: nil, messageIdentifiers: nil, spokenName: nil, unreadOnly: false)
        XCTAssertEqual(texts(all), ["one", "two", "three", "four"])
    }

    func test_aConversationIdentifierNamesTheMessagesExactly() {
        let found = SiriIntentPolicy.matchMessages(
            cache, conversationIdentifiers: ["p1"], messageIdentifiers: nil, spokenName: nil, unreadOnly: false)
        XCTAssertEqual(texts(found), ["one", "three"])
    }

    func test_aConversationIdentifierWinsOverASpokenName() {
        // "Anna" would also match p3, whose name differs only by case; the identifier says p2.
        let found = SiriIntentPolicy.matchMessages(
            cache, conversationIdentifiers: ["p2"], messageIdentifiers: nil, spokenName: "Anna", unreadOnly: false)
        XCTAssertEqual(texts(found), ["two"])
    }

    func test_aBlankConversationIdentifierIsNotACriterion() {
        let found = SiriIntentPolicy.matchMessages(
            cache, conversationIdentifiers: ["  "], messageIdentifiers: nil, spokenName: "Luca", unreadOnly: false)
        XCTAssertEqual(texts(found), ["two"])
    }

    func test_aSpokenNameMatchesIgnoringCase() {
        let found = SiriIntentPolicy.matchMessages(
            cache, conversationIdentifiers: nil, messageIdentifiers: nil, spokenName: " ANNA ", unreadOnly: false)
        XCTAssertEqual(texts(found), ["one", "three", "four"])
    }

    func test_messageIdentifiersNameMessagesExactlyAndWinOverTheRest() {
        let id = SiriIntentPolicy.messageIdentifier(peerUserId: "p1", sentAt: Date(timeIntervalSince1970: 300))
        let found = SiriIntentPolicy.matchMessages(
            cache, conversationIdentifiers: ["p2"], messageIdentifiers: [id], spokenName: "Luca", unreadOnly: false)
        XCTAssertEqual(texts(found), ["three"])
    }

    func test_unreadOnlyKeepsTheUnreadOnesAndTreatsUnknownAsRead() {
        let found = SiriIntentPolicy.matchMessages(
            cache, conversationIdentifiers: nil, messageIdentifiers: nil, spokenName: nil, unreadOnly: true)
        XCTAssertEqual(texts(found), ["one", "four"])
    }

    func test_unreadOnlyAndAConversationCombine() {
        let found = SiriIntentPolicy.matchMessages(
            cache, conversationIdentifiers: ["p1"], messageIdentifiers: nil, spokenName: nil, unreadOnly: true)
        XCTAssertEqual(texts(found), ["one"])
    }

    func test_aNameThatMatchesNobodyReturnsNothing() {
        let found = SiriIntentPolicy.matchMessages(
            cache, conversationIdentifiers: nil, messageIdentifiers: nil, spokenName: "Nobody", unreadOnly: false)
        XCTAssertTrue(found.isEmpty)
    }

    // MARK: - the signal between the extension and the app

    func test_theSignalOfTheExtensionReachesAnObserverInTheApp() {
        let arrived = expectation(description: "the signal arrived")
        arrived.assertForOverFulfill = false
        let observer = SiriBridgeSignalObserver { arrived.fulfill() }
        SiriBridgeSignal.post()
        wait(for: [arrived], timeout: 5)
        withExtendedLifetime(observer) {}
    }

    func test_anObserverThatWasReleasedHearsNothing() {
        let silent = expectation(description: "no signal")
        silent.isInverted = true
        var observer: SiriBridgeSignalObserver? = SiriBridgeSignalObserver { silent.fulfill() }
        observer = nil
        SiriBridgeSignal.post()
        wait(for: [silent], timeout: 1)
        XCTAssertNil(observer)
    }

    // MARK: - what the bridge stores

    func test_theQueuedRecordsKeepTheirNewFieldsThroughTheEncryptedFileFormat() throws {
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        let out = SiriMessageBridgeStore.OutboxMessage(
            id: "fixed-id", handle: "+39", spokenName: "Anna", text: "ciao", queuedAt: when,
            conversationIdentifier: "p1", customIdentifier: "p1")
        let outBack = try JSONDecoder().decode(
            SiriMessageBridgeStore.OutboxMessage.self, from: JSONEncoder().encode(out))
        XCTAssertEqual(outBack, out)
        XCTAssertEqual(outBack.conversationIdentifier, "p1")

        let mark = SiriMessageBridgeStore.ReadMark(id: "fixed-mark", peerUserId: "p1", upToSentAt: 1_699_999_999, queuedAt: when)
        let markBack = try JSONDecoder().decode(
            SiriMessageBridgeStore.ReadMark.self, from: JSONEncoder().encode(mark))
        XCTAssertEqual(markBack, mark)
        XCTAssertEqual(markBack.upToSentAt, 1_699_999_999)

        let cached = message("p1", "Anna", "x", at: 1, unread: true)
        let cachedBack = try JSONDecoder().decode(
            SiriMessageBridgeStore.CachedMessage.self, from: JSONEncoder().encode(cached))
        XCTAssertEqual(cachedBack, cached)
        XCTAssertEqual(cachedBack.isUnread, true)
    }
}
