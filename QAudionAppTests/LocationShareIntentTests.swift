import XCTest
@testable import QAudionApp

/// The "Share location" app intent (Siri, Shortcuts, Action button): which contacts the entity query may list, how it matches what
/// Siri heard, and when the intent runs or answers with a sentence and does nothing. Pure: the router's inputs are replaced.
///
/// Wired into CI: on the include list of `QAudionApp/project-apptests.yml` and in the `-only-testing` list of
/// `.github/workflows/ios-app-tests.yml`.
@MainActor
final class LocationShareIntentTests: XCTestCase {

    private let anna = LocationShareContactFacts(userId: "11111111-1111-1111-1111-111111111111", displayName: "Anna Rossi")
    private let bruno = LocationShareContactFacts(userId: "22222222-2222-2222-2222-222222222222", displayName: "Bruno Éco")
    private let carla = LocationShareContactFacts(userId: "33333333-3333-3333-3333-333333333333", displayName: "Carla Bianchi")

    private var savedFeature: (@MainActor () -> Bool)!
    private var savedSignedIn: (@MainActor () -> Bool)!
    private var savedLocked: (@MainActor () -> Bool)!
    private var savedContacts: (@MainActor () -> [LocationShareContactFacts])!
    private var savedBlocked: (@MainActor () -> Set<String>)!
    private var savedNow: (@MainActor () -> Date)!
    private var savedDeliver: (@MainActor (LocationShareRequest) -> Void)!

    private var delivered: [LocationShareRequest] = []

    override func setUp() {
        super.setUp()
        savedFeature = LocationShareIntentRouter.featureEnabled
        savedSignedIn = LocationShareIntentRouter.signedIn
        savedLocked = LocationShareIntentRouter.appLocked
        savedContacts = LocationShareIntentRouter.allContacts
        savedBlocked = LocationShareIntentRouter.blockedIds
        savedNow = LocationShareIntentRouter.now
        savedDeliver = LocationShareIntentRouter.deliver
        delivered = []
        let everyone: [LocationShareContactFacts] = [carla, anna, bruno]
        LocationShareIntentRouter.featureEnabled = { true }
        LocationShareIntentRouter.signedIn = { true }
        LocationShareIntentRouter.appLocked = { false }
        LocationShareIntentRouter.allContacts = { everyone }
        LocationShareIntentRouter.blockedIds = { [] }
        LocationShareIntentRouter.now = { Date(timeIntervalSince1970: 1_000) }
        LocationShareIntentRouter.deliver = { [weak self] request in self?.delivered.append(request) }
    }

    override func tearDown() {
        LocationShareIntentRouter.featureEnabled = savedFeature
        LocationShareIntentRouter.signedIn = savedSignedIn
        LocationShareIntentRouter.appLocked = savedLocked
        LocationShareIntentRouter.allContacts = savedContacts
        LocationShareIntentRouter.blockedIds = savedBlocked
        LocationShareIntentRouter.now = savedNow
        LocationShareIntentRouter.deliver = savedDeliver
        LocationShareCenter.featureOverride = nil
        super.tearDown()
    }

    // MARK: Entity query filtering

    func testListableSortsByNameAndDropsDuplicatesAndEmptyValues() {
        let dirty: [LocationShareContactFacts] = [
            carla, anna, anna,
            LocationShareContactFacts(userId: "", displayName: "Nobody"),
            LocationShareContactFacts(userId: "44444444-4444-4444-4444-444444444444", displayName: "   ")
        ]
        let listed = LocationShareIntentPolicy.listable(dirty, blocked: [], signedIn: true, appLocked: false)
        XCTAssertEqual(listed.map { $0.displayName }, ["Anna Rossi", "Carla Bianchi"])
    }

    func testListableLeavesOutBlockedContacts() {
        let listed = LocationShareIntentPolicy.listable([anna, bruno, carla], blocked: [bruno.userId], signedIn: true, appLocked: false)
        XCTAssertEqual(listed.map { $0.userId }, [anna.userId, carla.userId])
    }

    func testListableIsEmptyWhileSignedOutOrLocked() {
        XCTAssertTrue(LocationShareIntentPolicy.listable([anna], blocked: [], signedIn: false, appLocked: false).isEmpty)
        XCTAssertTrue(LocationShareIntentPolicy.listable([anna], blocked: [], signedIn: true, appLocked: true).isEmpty)
    }

    func testMatchingIgnoresCaseAndAccents() {
        let all: [LocationShareContactFacts] = [anna, bruno, carla]
        XCTAssertEqual(LocationShareIntentPolicy.matching(all, query: "bruno eco").map { $0.userId }, [bruno.userId])
        XCTAssertEqual(LocationShareIntentPolicy.matching(all, query: "ROSSI").map { $0.userId }, [anna.userId])
        XCTAssertEqual(LocationShareIntentPolicy.matching(all, query: "a").count, 2)
    }

    func testMatchingAnEmptyQueryMatchesNobody() {
        XCTAssertTrue(LocationShareIntentPolicy.matching([anna, bruno], query: "").isEmpty)
        XCTAssertTrue(LocationShareIntentPolicy.matching([anna, bruno], query: "   ").isEmpty)
    }

    func testResolvingKeepsTheOrderAskedAndSkipsUnknownIds() {
        let found = LocationShareIntentPolicy.resolving([anna, bruno, carla], ids: [carla.userId, "unknown", anna.userId])
        XCTAssertEqual(found.map { $0.userId }, [carla.userId, anna.userId])
    }

    func testRouterListsOnlyWhatThePolicyAllows() {
        let blockedId: String = anna.userId
        LocationShareIntentRouter.blockedIds = { [blockedId] }
        XCTAssertEqual(LocationShareIntentRouter.listableContacts().map { $0.userId }, [bruno.userId, carla.userId])
        LocationShareIntentRouter.appLocked = { true }
        XCTAssertTrue(LocationShareIntentRouter.listableContacts().isEmpty)
        LocationShareIntentRouter.appLocked = { false }
        LocationShareIntentRouter.signedIn = { false }
        XCTAssertTrue(LocationShareIntentRouter.listableContacts().isEmpty)
    }

    // MARK: Gating

    func testGateOrder() {
        XCTAssertEqual(LocationShareIntentPolicy.gate(featureEnabled: false, signedIn: false, contactAvailable: false), .featureOff)
        XCTAssertEqual(LocationShareIntentPolicy.gate(featureEnabled: true, signedIn: false, contactAvailable: false), .signedOut)
        XCTAssertEqual(LocationShareIntentPolicy.gate(featureEnabled: true, signedIn: true, contactAvailable: false), .contactNotFound)
        XCTAssertEqual(LocationShareIntentPolicy.gate(featureEnabled: true, signedIn: true, contactAvailable: true), .proceed)
    }

    func testFeatureSeamFollowsTheRemoteSwitch() {
        LocationShareIntentRouter.featureEnabled = savedFeature
        LocationShareCenter.featureOverride = false
        XCTAssertFalse(LocationShareIntentRouter.featureEnabled())
        LocationShareCenter.featureOverride = true
        XCTAssertTrue(LocationShareIntentRouter.featureEnabled())
    }

    func testFeatureOffAnswersAndDeliversNothing() {
        LocationShareIntentRouter.featureEnabled = { false }
        XCTAssertEqual(LocationShareIntentRouter.handle(contactId: anna.userId, mode: .instant), .featureOff)
        XCTAssertTrue(delivered.isEmpty)
    }

    func testSignedOutAnswersAndDeliversNothing() {
        LocationShareIntentRouter.signedIn = { false }
        XCTAssertEqual(LocationShareIntentRouter.handle(contactId: anna.userId, mode: .live(seconds: 900)), .signedOut)
        XCTAssertTrue(delivered.isEmpty)
    }

    func testUnknownOrBlockedContactDeliversNothing() {
        XCTAssertEqual(LocationShareIntentRouter.handle(contactId: "unknown", mode: .instant), .contactNotFound)
        let blockedId: String = anna.userId
        LocationShareIntentRouter.blockedIds = { [blockedId] }
        XCTAssertEqual(LocationShareIntentRouter.handle(contactId: anna.userId, mode: .instant), .contactNotFound)
        XCTAssertTrue(delivered.isEmpty)
    }

    func testAnInstantRequestIsHandedOffOnce() {
        XCTAssertEqual(LocationShareIntentRouter.handle(contactId: anna.userId, mode: .instant), .handedOff)
        XCTAssertEqual(delivered, [LocationShareRequest(peerUserId: anna.userId, mode: .instant, createdAt: Date(timeIntervalSince1970: 1_000))])
    }

    func testALiveRequestKeepsItsDuration() {
        XCTAssertEqual(LocationShareIntentRouter.handle(contactId: bruno.userId, mode: .live(seconds: 3_600)), .handedOff)
        XCTAssertEqual(delivered.first?.mode.suggestedLiveSeconds, 3_600)
    }

    func testTheLockHidesNamesButNotTheHandOff() {
        LocationShareIntentRouter.appLocked = { true }
        XCTAssertTrue(LocationShareIntentRouter.listableContacts().isEmpty)
        XCTAssertEqual(LocationShareIntentRouter.handle(contactId: anna.userId, mode: .instant), .handedOff)
    }

    // MARK: Request

    func testOnlyThePresetDurationsAreHighlighted() {
        XCTAssertNil(LocationShareRequestMode.instant.suggestedLiveSeconds)
        XCTAssertNil(LocationShareRequestMode.live(seconds: 777).suggestedLiveSeconds)
        for seconds in LocationShareRequestMode.livePresets {
            XCTAssertEqual(LocationShareRequestMode.live(seconds: seconds).suggestedLiveSeconds, seconds)
        }
        XCTAssertEqual(LocationShareRequestMode.livePresets, [900, 3_600, 28_800, 86_400])
    }

    func testARequestExpiresAndIsMeantForOneChat() {
        let request = LocationShareRequest(peerUserId: anna.userId, mode: .instant, createdAt: Date(timeIntervalSince1970: 1_000))
        XCTAssertTrue(LocationShareIntentPolicy.isFresh(request, now: Date(timeIntervalSince1970: 1_060)))
        XCTAssertFalse(LocationShareIntentPolicy.isFresh(request, now: Date(timeIntervalSince1970: 1_000 + LocationShareIntentPolicy.requestLifetime + 1)))
        XCTAssertFalse(LocationShareIntentPolicy.isFresh(request, now: Date(timeIntervalSince1970: 900)))
        XCTAssertTrue(LocationShareIntentPolicy.matches(request, peerUserId: anna.userId))
        XCTAssertFalse(LocationShareIntentPolicy.matches(request, peerUserId: bruno.userId))
        XCTAssertFalse(LocationShareIntentPolicy.matches(request, peerUserId: ""))
    }

    // MARK: Sentences

    func testEverySentenceIsNonEmptyAndCarriesNoIdentity() {
        let outcomes: [LocationShareIntentRouter.Outcome] = [.handedOff, .featureOff, .signedOut, .contactNotFound]
        for outcome in outcomes {
            let text = LocationShareIntentStrings.dialog(for: outcome)
            XCTAssertFalse(text.isEmpty)
            XCTAssertFalse(text.contains(anna.userId))
            XCTAssertFalse(text.contains("Anna"))
        }
    }
}
