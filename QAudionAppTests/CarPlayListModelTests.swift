import XCTest
@testable import QAudionApp
import QAudionEngine

/// The lists of the CarPlay scene (`CarPlayListModel.swift`), which compile in every build: how many rows a tab may
/// have (the template's own maximum, and 12 where the vehicle limits lists), which rows are left out, in which order
/// they come, and what an empty tab says. Also the gate that makes `AppState.initialize()` run once when the app can
/// be reached by the phone window and by the CarPlay scene.
///
/// Wired into CI: on the include list of `QAudionApp/project-apptests.yml` and in the `-only-testing` list of
/// `.github/workflows/ios-app-tests.yml`.
final class CarPlayListModelTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 2_000_000)

    private func resolve(_ userId: String) -> String { "name-of-\(userId)" }

    private func limits(_ maximum: Int, limited: Bool = false) -> CarPlayListLimits {
        CarPlayListLimits(templateMaximumItems: maximum, listsLimited: limited)
    }

    private func record(
        _ n: Int, name: String = "Mario", direction: CallRecord.Direction = .outgoing, seconds: Double? = nil,
        video: Bool = false
    ) -> CallRecord {
        CallRecord(
            id: "call-\(n)", peerUserId: "peer-\(n)", peerDisplayName: name, direction: direction,
            startedAt: t0, endedAt: seconds.map { t0.addingTimeInterval($0) }, isVideo: video, peerExtension: nil)
    }

    private func contact(_ id: String, _ name: String, verified: Bool = false, phone: String? = nil)
        -> ContactsStore.StoredContact
    {
        ContactsStore.StoredContact(
            userId: id, displayName: name, phoneHash: "unused", avatarUrl: nil, lastSeen: nil,
            isVerified: verified, phoneNumber: phone)
    }

    private func conversation(
        _ n: Int, name: String = "Anna", unread: Int = 0, pinned: Bool = false, kind: Conversation.Kind = .oneToOne
    ) -> Conversation {
        Conversation(
            id: UUID(), peerUserId: "peer-\(n)", peerDisplayName: name, lastMessagePreview: nil,
            lastActivity: t0, unreadCount: unread, pinned: pinned, kind: kind)
    }

    // MARK: - limits

    func test_theCapIsTheSmallestOfWhatTheAppWantsWhatTheTemplateAllowsAndTwelveOnALimitedVehicle() {
        XCTAssertEqual(limits(100).cap(wanted: 50), 50)
        XCTAssertEqual(limits(30).cap(wanted: 50), 30)
        XCTAssertEqual(limits(100, limited: true).cap(wanted: 50), 12)
        XCTAssertEqual(limits(8, limited: true).cap(wanted: 50), 8)
        XCTAssertEqual(limits(100, limited: true).cap(wanted: 5), 5)
    }

    func test_theCapIsNeverNegative() {
        XCTAssertEqual(limits(-3).cap(wanted: 20), 0)
        XCTAssertEqual(limits(100).cap(wanted: -1), 0)
        XCTAssertEqual(limits(0, limited: true).cap(wanted: 20), 0)
    }

    func test_beforeCarPlaySaysAnythingTheStrictestCaseIsAssumed() {
        XCTAssertEqual(CarPlayListLimits.conservative.cap(wanted: 50), 12)
        XCTAssertEqual(CarPlayListLimits.limitedListItemCount, 12)
    }

    // MARK: - recents

    func test_recentsStopAtTheCap() {
        let records = (0..<40).map { record($0) }
        XCTAssertEqual(CarPlayListBuilder.recents(records, limits: limits(100), resolve: resolve).count, 20)
        XCTAssertEqual(CarPlayListBuilder.recents(records, limits: limits(100, limited: true), resolve: resolve).count, 12)
        XCTAssertEqual(CarPlayListBuilder.recents(records, limits: limits(7), resolve: resolve).count, 7)
    }

    func test_recentsKeepTheOrderOfTheHistory() {
        let rows = CarPlayListBuilder.recents((0..<5).map { record($0) }, limits: limits(100), resolve: resolve)
        XCTAssertEqual(rows.map { $0.peerUserId }, ["peer-0", "peer-1", "peer-2", "peer-3", "peer-4"])
    }

    func test_aRecentRowCarriesDirectionDurationAndVideo() {
        let rows = CarPlayListBuilder.recents(
            [record(1, direction: .incoming, seconds: 75, video: true), record(2, direction: .missed)],
            limits: limits(100), resolve: resolve)
        XCTAssertEqual(rows[0].direction, .incoming)
        XCTAssertEqual(rows[0].durationSeconds, 75)
        XCTAssertTrue(rows[0].isVideo)
        XCTAssertEqual(rows[1].direction, .missed)
        XCTAssertNil(rows[1].durationSeconds)
        XCTAssertFalse(rows[1].isVideo)
    }

    func test_theStoredNameIsShownUnlessItIsEmptyOrOnlyAnId() {
        let uuid = "0F8FAD5B-D9CB-469F-A165-70867728950E"
        let hex = "0f8fad5bd9cb469fa16570867728950e"
        let rows = CarPlayListBuilder.recents(
            [record(1, name: "Mario Rossi"), record(2, name: ""), record(3, name: "   "), record(4, name: uuid),
             record(5, name: hex)],
            limits: limits(100), resolve: resolve)
        XCTAssertEqual(rows.map { $0.title }, ["Mario Rossi", "name-of-peer-2", "name-of-peer-3", "name-of-peer-4", "name-of-peer-5"])
    }

    // MARK: - contacts

    func test_contactsAreVerifiedFirstThenByNameIgnoringCase() {
        let rows = CarPlayListBuilder.contacts(
            [contact("a", "zeta"), contact("b", "Beta", verified: true), contact("c", "alfa"), contact("d", "Omega", verified: true)],
            orphanPeerIds: [], limits: limits(100), resolve: { id in ["a": "zeta", "b": "Beta", "c": "alfa", "d": "Omega"][id]! })
        XCTAssertEqual(rows.map { $0.title }, ["Beta", "Omega", "alfa", "zeta"])
        XCTAssertEqual(rows.map { $0.isVerified }, [true, true, false, false])
    }

    func test_contactsWhoseAccountNoLongerExistsAreLeftOut() {
        let rows = CarPlayListBuilder.contacts(
            [contact("a", "A"), contact("b", "B"), contact("c", "C")],
            orphanPeerIds: ["b"], limits: limits(100), resolve: { $0.uppercased() })
        XCTAssertEqual(rows.map { $0.userId }, ["a", "c"])
    }

    func test_contactsStopAtTheCapAfterTheOrderIsDecided() {
        let all = (0..<80).map { contact("id-\($0)", "Name \($0)", verified: $0 == 79) }
        let wide = CarPlayListBuilder.contacts(all, orphanPeerIds: [], limits: limits(100), resolve: { id in
            all.first { $0.userId == id }!.displayName })
        XCTAssertEqual(wide.count, 50)
        XCTAssertEqual(wide.first?.userId, "id-79", "the verified one is kept when the rest is cut")
        let narrow = CarPlayListBuilder.contacts(all, orphanPeerIds: [], limits: limits(100, limited: true), resolve: { id in
            all.first { $0.userId == id }!.displayName })
        XCTAssertEqual(narrow.count, 12)
        XCTAssertEqual(narrow.first?.userId, "id-79")
    }

    func test_aContactRowUsesTheResolvedNameAndKeepsThePhoneNumber() {
        let rows = CarPlayListBuilder.contacts(
            [contact("a", "Phone #100", phone: "+390212345678")], orphanPeerIds: [], limits: limits(100),
            resolve: { _ in "Anna Verdi" })
        XCTAssertEqual(rows.first?.title, "Anna Verdi")
        XCTAssertEqual(rows.first?.phoneNumber, "+390212345678")
    }

    // MARK: - conversations

    func test_onlyOneToOneConversationsAreListed() {
        let rows = CarPlayListBuilder.conversations(
            [conversation(1), conversation(2, kind: .group), conversation(3)], limits: limits(100), resolve: resolve)
        XCTAssertEqual(rows.map { $0.conversationIdentifier }, ["peer-1", "peer-3"])
    }

    func test_aConversationRowNamesItsPeerAndCountsUnread() {
        let rows = CarPlayListBuilder.conversations(
            [conversation(1, name: "Anna", unread: 3, pinned: true), conversation(2, name: "", unread: -4)],
            limits: limits(100), resolve: resolve)
        XCTAssertEqual(rows[0].conversationIdentifier, "peer-1")
        XCTAssertEqual(rows[0].title, "Anna")
        XCTAssertEqual(rows[0].unreadCount, 3)
        XCTAssertTrue(rows[0].isPinned)
        XCTAssertEqual(rows[1].title, "name-of-peer-2")
        XCTAssertEqual(rows[1].unreadCount, 0, "a negative count never reaches the screen")
    }

    func test_conversationsStopAtTheCap() {
        let all = (0..<40).map { conversation($0) }
        XCTAssertEqual(CarPlayListBuilder.conversations(all, limits: limits(100), resolve: resolve).count, 20)
        XCTAssertEqual(CarPlayListBuilder.conversations(all, limits: limits(100, limited: true), resolve: resolve).count, 12)
    }

    func test_groupsDoNotTakeUpRoomUnderTheCap() {
        let all = (0..<30).map { conversation($0, kind: $0 < 25 ? .group : .oneToOne) }
        XCTAssertEqual(CarPlayListBuilder.conversations(all, limits: limits(100), resolve: resolve).count, 5)
    }

    // MARK: - pinned

    func test_pinnedConversationsAreTheOneToOneOnesThatArePinned() {
        let rows = CarPlayListBuilder.pinnedConversations(
            [conversation(1, pinned: true), conversation(2), conversation(3, pinned: true, kind: .group), conversation(4, pinned: true)],
            maximum: 8, resolve: resolve)
        XCTAssertEqual(rows.map { $0.conversationIdentifier }, ["peer-1", "peer-4"])
        XCTAssertTrue(rows.allSatisfy { $0.isPinned })
    }

    func test_pinnedConversationsStopAtTheMaximumOfTheHeader() {
        let all = (0..<10).map { conversation($0, pinned: true) }
        XCTAssertEqual(CarPlayListBuilder.pinnedConversations(all, maximum: 4, resolve: resolve).count, 4)
        XCTAssertEqual(CarPlayListBuilder.pinnedConversations(all, maximum: 0, resolve: resolve).count, 0)
        XCTAssertEqual(CarPlayListBuilder.pinnedConversations(all, maximum: -2, resolve: resolve).count, 0)
    }

    // MARK: - empty states

    func test_aSessionThatIsNotKnownYetIsNotASignedOutApp() {
        // A launch made by the car: the stored session is checked after the start-up, so for a while nobody is
        // "signed in" and nobody is "signed out" either.
        XCTAssertEqual(CarPlaySession.of(isAuthenticated: false, hasStoredSession: true), .unknown)
        XCTAssertEqual(CarPlaySession.of(isAuthenticated: false, hasStoredSession: false), .signedOut)
        XCTAssertEqual(CarPlaySession.of(isAuthenticated: true, hasStoredSession: true), .signedIn)
        XCTAssertEqual(CarPlaySession.of(isAuthenticated: true, hasStoredSession: false), .signedIn)
    }

    func test_whatTheCarMayShowFollowsTheSessionAndTheLock() {
        XCTAssertEqual(CarPlayListBuilder.access(session: .signedIn, isLocked: false), .open)
        XCTAssertEqual(CarPlayListBuilder.access(session: .unknown, isLocked: false), .starting)
        XCTAssertEqual(CarPlayListBuilder.access(session: .signedOut, isLocked: false), .signedOut)
    }

    func test_aLockedAppShowsNothingWhateverTheSessionIs() {
        for session in [CarPlaySession.signedIn, .unknown, .signedOut] {
            XCTAssertEqual(CarPlayListBuilder.access(session: session, isLocked: true), .locked)
        }
    }

    func test_anAppThatIsNotOpenListsNothingAndSaysWhy() {
        for tab in CarPlayTab.allCases {
            XCTAssertEqual(CarPlayListBuilder.emptyKind(for: tab, access: .open), .nothingYet(tab))
            XCTAssertEqual(CarPlayListBuilder.emptyKind(for: tab, access: .starting), .starting)
            XCTAssertEqual(CarPlayListBuilder.emptyKind(for: tab, access: .signedOut), .signedOut)
            XCTAssertEqual(CarPlayListBuilder.emptyKind(for: tab, access: .locked), .locked)
        }
    }

    func test_durations() {
        XCTAssertEqual(CarPlayListBuilder.formatDuration(0), "00:00")
        XCTAssertEqual(CarPlayListBuilder.formatDuration(9), "00:09")
        XCTAssertEqual(CarPlayListBuilder.formatDuration(75), "01:15")
        XCTAssertEqual(CarPlayListBuilder.formatDuration(3599), "59:59")
        XCTAssertEqual(CarPlayListBuilder.formatDuration(3600), "1:00:00")
        XCTAssertEqual(CarPlayListBuilder.formatDuration(3725), "1:02:05")
        XCTAssertEqual(CarPlayListBuilder.formatDuration(-5), "00:00")
    }

    func test_thereAreExactlyFourNoticesAndThreeTabs() {
        XCTAssertEqual(CarPlayNotice.allCases.count, 4)
        XCTAssertEqual(CarPlayTab.allCases.count, 3)
    }

    // MARK: - the start-up gate

    func test_theCarStartsTheAppFirst_theWindowThatFollowsDoesNotRunItAgain() {
        var gate = AppInitializeGate()
        XCTAssertTrue(gate.carPlayNeedsInitialize())
        XCTAssertFalse(gate.carPlayNeedsInitialize(), "a second connection of the car finds it done")
        XCTAssertFalse(gate.phoneWindowNeedsInitialize(), "the first window after the car skips the duplicate")
        XCTAssertTrue(gate.phoneWindowNeedsInitialize(), "a window that appears again runs it again, as before")
    }

    func test_theWindowStartsTheAppFirst_theCarFindsItDone() {
        var gate = AppInitializeGate()
        XCTAssertTrue(gate.phoneWindowNeedsInitialize())
        XCTAssertFalse(gate.carPlayNeedsInitialize())
        XCTAssertTrue(gate.phoneWindowNeedsInitialize())
    }

    func test_withoutTheCarTheWindowAlwaysRunsIt() {
        var gate = AppInitializeGate()
        for _ in 0..<4 { XCTAssertTrue(gate.phoneWindowNeedsInitialize()) }
        XCTAssertEqual(gate.runs, 4)
    }
}
