import XCTest
@testable import QAudionEngine

final class SettingsStoreTests: XCTestCase {

    private var defaults: UserDefaults!
    private var store: SettingsStore!

    override func setUp() {
        super.setUp()
        // In-memory UserDefaults via a unique suite name per test.
        let suite = "test.settingsstore.\(UUID().uuidString)"
        UserDefaults().removePersistentDomain(forName: suite)
        // Suite name is a freshly generated, well-formed non-empty string; UserDefaults(suiteName:) never returns nil for it.
        // swiftlint:disable:next force_unwrapping
        defaults = UserDefaults(suiteName: suite)!
        store = SettingsStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: defaults.dictionaryRepresentation().keys.first ?? "")
        store = nil
        defaults = nil
        super.tearDown()
    }

    // MARK: - Privacy

    func test_privacy_defaultsAreSecureBiased() {
        let p = store.loadPrivacy()
        XCTAssertTrue(p.readReceiptsEnabled)
        XCTAssertTrue(p.typingIndicatorEnabled)
        XCTAssertTrue(p.presenceVisibleToContacts)
        XCTAssertEqual(p.disappearingMessagesDuration, 0)
        XCTAssertEqual(p.blockedUserIds, [])
        XCTAssertFalse(p.torEnabled)
    }

    func test_privacy_saveAndLoadRoundTrip() {
        let saved = PrivacySettingsViewModel(
            readReceiptsEnabled: false,
            typingIndicatorEnabled: false,
            presenceVisibleToContacts: false,
            disappearingMessagesDuration: 3600,
            blockedUserIds: ["user-x", "user-y"],
            torEnabled: true
        )
        store.savePrivacy(saved)
        let loaded = store.loadPrivacy()
        XCTAssertEqual(loaded, saved)
    }

    // MARK: - Chat

    func test_chat_defaultsAreSecureBiased() {
        let c = store.loadChat()
        XCTAssertTrue(c.readReceiptsEnabled)
        XCTAssertTrue(c.typingIndicatorsEnabled)
        XCTAssertFalse(c.messagePreviewInNotifications)
    }

    func test_chat_roundTrip() {
        let saved = ChatSettingsViewModel(
            readReceiptsEnabled: false,
            typingIndicatorsEnabled: false,
            messagePreviewInNotifications: true
        )
        store.saveChat(saved)
        XCTAssertEqual(store.loadChat(), saved)
    }

    // MARK: - Calls

    func test_calls_defaultsAreOpusAecOn() {
        let c = store.loadCalls()
        XCTAssertEqual(c.codecPreference, .opus)
        XCTAssertTrue(c.isAecEnabled)
        XCTAssertTrue(c.isNsEnabled)
        XCTAssertTrue(c.isAgcEnabled)
    }

    func test_calls_roundTrip() {
        let saved = CallsSettingsViewModel(
            codecPreference: .opus,
            isAecEnabled: false,
            isNsEnabled: false,
            isAgcEnabled: false,
            isVoipBackgroundModeActive: true,
            preferredCallQuality: .high
        )
        store.saveCalls(saved)
        XCTAssertEqual(store.loadCalls(), saved)
    }

    // MARK: - Transport

    func test_transport_defaultsToAutoMode() {
        let t = store.loadTransport()
        XCTAssertEqual(t.mode, .auto)
        XCTAssertFalse(t.torEnabled)
        XCTAssertNil(t.preferredTurnServerUrl)
    }

    func test_transport_roundTrip() {
        let saved = TransportSettingsViewModel(
            mode: .turn,
            torEnabled: true,
            preferredTurnServerUrl: URL(string: "turn://relay.example.com:3478"),
            lastConnectionMs: 200,
            lastTurnRoundTripMs: 50
        )
        store.saveTransport(saved)
        XCTAssertEqual(store.loadTransport(), saved)
    }

    // MARK: - Notifications

    func test_notifications_defaultsAreReasonable() {
        let n = store.loadNotifications()
        XCTAssertEqual(n.ringtoneId, "qaudion-default")
        XCTAssertTrue(n.inAppSoundEnabled)
        XCTAssertTrue(n.vibrationEnabled)
        XCTAssertFalse(n.quietHours.enabled)
        XCTAssertEqual(n.mutedContactsCount, 0)
    }

    func test_notifications_roundTrip() {
        let saved = NotificationsSettingsViewModel(
            ringtoneId: "alpha",
            inAppSoundEnabled: false,
            vibrationEnabled: false,
            quietHours: NotificationsSettingsViewModel.QuietHours(
                startHour: 23, startMinute: 30, endHour: 7, endMinute: 15, enabled: true
            ),
            mutedContactsCount: 5
        )
        store.saveNotifications(saved)
        XCTAssertEqual(store.loadNotifications(), saved)
    }

    // MARK: - Reset

    func test_resetAll_clearsEverything() {
        store.savePrivacy(.mock)
        store.saveChat(.mock)
        store.resetAll()
        // After reset, loaders return defaults.
        XCTAssertTrue(store.loadPrivacy().readReceiptsEnabled)
        XCTAssertTrue(store.loadChat().readReceiptsEnabled)
    }
}
