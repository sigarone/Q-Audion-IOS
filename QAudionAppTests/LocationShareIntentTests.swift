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
    private var savedAccount: (@MainActor () -> String?)!
    private var savedUpdate: (@MainActor () -> Void)!
    private var updates = 0
    private let account = "99999999-9999-9999-9999-999999999999"

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
        savedAccount = LocationShareIntentRouter.accountId
        savedUpdate = LocationShareIntentRouter.updateShortcutParameters
        delivered = []
        updates = 0
        let me: String = account
        LocationShareIntentRouter.accountId = { me }
        LocationShareIntentRouter.updateShortcutParameters = { [weak self] in self?.updates += 1 }
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
        LocationShareIntentRouter.accountId = savedAccount
        LocationShareIntentRouter.updateShortcutParameters = savedUpdate
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
        XCTAssertEqual(delivered, [LocationShareRequest(accountId: account, peerUserId: anna.userId, mode: .instant, createdAt: Date(timeIntervalSince1970: 1_000))])
    }

    func testALiveRequestKeepsItsDuration() {
        XCTAssertEqual(LocationShareIntentRouter.handle(contactId: bruno.userId, mode: .live(seconds: 3_600)), .handedOff)
        XCTAssertEqual(delivered.first?.mode.suggestedLiveSeconds, 3_600)
    }

    func testTheLockHidesTheListButStillResolvesHeldIdsAndHandsOff() {
        LocationShareIntentRouter.appLocked = { true }
        XCTAssertTrue(LocationShareIntentRouter.listableContacts().isEmpty)
        // An id Siri already holds still resolves (it reveals nothing new), so the hand-off waits behind the lock screen.
        let held = LocationShareIntentPolicy.resolving(LocationShareIntentRouter.resolvableContacts(), ids: [anna.userId])
        XCTAssertEqual(held.map { $0.userId }, [anna.userId])
        XCTAssertTrue(LocationShareIntentPolicy.resolving(LocationShareIntentRouter.resolvableContacts(), ids: ["unknown"]).isEmpty)
        XCTAssertEqual(LocationShareIntentRouter.handle(contactId: anna.userId, mode: .instant), .handedOff)
        XCTAssertEqual(delivered.count, 1)
    }

    func testResolvableStillHonoursBlockAndSignOut() {
        let blockedId: String = anna.userId
        LocationShareIntentRouter.blockedIds = { [blockedId] }
        XCTAssertTrue(LocationShareIntentRouter.resolvableContacts().allSatisfy { $0.userId != blockedId })
        LocationShareIntentRouter.signedIn = { false }
        XCTAssertTrue(LocationShareIntentRouter.resolvableContacts().isEmpty)
    }

    func testParametersAreRefreshedThroughTheSeam() {
        LocationShareIntentRouter.shortcutParametersChanged()
        LocationShareIntentRouter.shortcutParametersChanged()
        XCTAssertEqual(updates, 2)
    }

    // MARK: Lock at a cold start

    func testNamesAreLockedUntilTheLockHasSaidOtherwise() {
        let now = Date(timeIntervalSince1970: 10_000)
        func locked(enabled: Bool = true, isLocked: Bool = false, active: Bool = true, at: Date? = nil) -> Bool {
            LocationShareIntentPolicy.namesAreLocked(
                lockEnabled: enabled, isLocked: isLocked, appActive: active, backgroundedAt: at, graceSeconds: 60, now: now)
        }
        XCTAssertFalse(locked(enabled: false, isLocked: true))
        XCTAssertTrue(locked(isLocked: true))
        XCTAssertTrue(locked(at: Date(timeIntervalSince1970: 9_000)))
        XCTAssertFalse(locked(active: false, at: Date(timeIntervalSince1970: 9_990)))
        XCTAssertTrue(locked(active: false, at: nil))
        XCTAssertFalse(locked(active: true, at: nil))
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
        let request = LocationShareRequest(accountId: account, peerUserId: anna.userId, mode: .instant, createdAt: Date(timeIntervalSince1970: 1_000))
        XCTAssertTrue(LocationShareIntentPolicy.isFresh(request, now: Date(timeIntervalSince1970: 1_060)))
        XCTAssertFalse(LocationShareIntentPolicy.isFresh(request, now: Date(timeIntervalSince1970: 1_000 + LocationShareIntentPolicy.requestLifetime + 1)))
        XCTAssertFalse(LocationShareIntentPolicy.isFresh(request, now: Date(timeIntervalSince1970: 900)))
        XCTAssertTrue(LocationShareIntentPolicy.matches(request, peerUserId: anna.userId, accountId: account))
        XCTAssertFalse(LocationShareIntentPolicy.matches(request, peerUserId: bruno.userId, accountId: account))
        XCTAssertFalse(LocationShareIntentPolicy.matches(request, peerUserId: "", accountId: account))
        XCTAssertFalse(LocationShareIntentPolicy.matches(request, peerUserId: anna.userId, accountId: "other"))
        XCTAssertFalse(LocationShareIntentPolicy.matches(request, peerUserId: anna.userId, accountId: ""))
    }

    func testARequestIsTakenOnceAndNeverUnderAnotherAccount() {
        let made = Date(timeIntervalSince1970: 1_000)
        let now = Date(timeIntervalSince1970: 1_010)
        let request = LocationShareRequest(accountId: account, peerUserId: anna.userId, mode: .live(seconds: 900), createdAt: made)

        var slot: LocationShareRequest? = request
        XCTAssertNil(LocationShareIntentPolicy.take(&slot, peerUserId: bruno.userId, accountId: account, now: now))
        XCTAssertEqual(slot, request, "a request for another chat waits for its chat")
        XCTAssertEqual(LocationShareIntentPolicy.take(&slot, peerUserId: anna.userId, accountId: account, now: now), request)
        XCTAssertNil(slot, "taken: the slot is empty")
        XCTAssertNil(LocationShareIntentPolicy.take(&slot, peerUserId: anna.userId, accountId: account, now: now), "one shot")

        slot = request
        XCTAssertNil(LocationShareIntentPolicy.take(&slot, peerUserId: anna.userId, accountId: "another-account", now: now))
        XCTAssertNil(slot, "a request of another account is dropped")

        slot = request
        XCTAssertNil(LocationShareIntentPolicy.take(&slot, peerUserId: anna.userId, accountId: account,
                                                    now: Date(timeIntervalSince1970: 1_000 + LocationShareIntentPolicy.requestLifetime + 1)))
        XCTAssertNil(slot, "a stale request is dropped")
    }

    // MARK: Phrases

    /// The phrase templates of `QAudionAppShortcuts` (the Italian text of the code, the key of every strings file).
    private let phraseTemplates: Set<String> = [
        "Condividi la posizione con ${contact} su ${applicationName}",
        "Manda la mia posizione a ${contact} su ${applicationName}",
        "Condividi la mia posizione su ${applicationName}"
    ]

    func testEveryLanguageHasExactlyThePhraseTemplatesAndNamesTheApp() throws {
        // The test runs from a checkout: the strings files are read from the source tree next to this file.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("QAudionApp")
        for lang in ["it", "en", "es", "fr", "de", "pt-BR"] {
            let url = root.appendingPathComponent("\(lang).lproj/AppShortcuts.strings")
            guard let table = NSDictionary(contentsOf: url) as? [String: String] else {
                XCTFail("\(lang): AppShortcuts.strings missing or unreadable")
                continue
            }
            XCTAssertEqual(Set(table.keys), phraseTemplates, "\(lang): keys differ from the phrase templates")
            for (key, value) in table {
                XCTAssertTrue(value.contains("${applicationName}"), "\(lang): a phrase does not name the app")
                XCTAssertEqual(key.contains("${contact}"), value.contains("${contact}"), "\(lang): contact placeholder differs")
            }
        }
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
