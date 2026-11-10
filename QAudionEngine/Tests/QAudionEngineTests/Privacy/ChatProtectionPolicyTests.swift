import XCTest
@testable import QAudionEngine

/// Which conversations are protected, and that a protected conversation never keeps message text as its list preview.
final class ChatProtectionPolicyTests: XCTestCase {

    private let marker = ChatProtectionPolicy.protectedPreviewMarker
    private let label = "LABEL"

    override func setUp() {
        super.setUp()
        LocalStoreCipher.testKeyOverride = Data(repeating: 0x5c, count: 32)
        ChatProtectionPolicy.maskStoredPreviews = true
    }

    override func tearDown() {
        ChatProtectionPolicy.maskStoredPreviews = false
        LocalStoreCipher.testKeyOverride = nil
        super.tearDown()
    }

    // MARK: - Decision

    func test_lockOnAndNoGrant_isProtected() {
        XCTAssertTrue(ChatProtectionPolicy.isProtected(lockEnabled: true, peerGranted: nil, ephemeralTimerSeconds: nil))
        XCTAssertTrue(ChatProtectionPolicy.isProtected(lockEnabled: true, peerGranted: false, ephemeralTimerSeconds: 0))
    }

    func test_peerGrant_unprotects() {
        XCTAssertFalse(ChatProtectionPolicy.isProtected(lockEnabled: true, peerGranted: true, ephemeralTimerSeconds: nil))
    }

    func test_lockOff_isNotProtected() {
        XCTAssertFalse(ChatProtectionPolicy.isProtected(lockEnabled: false, peerGranted: nil, ephemeralTimerSeconds: nil))
    }

    func test_timerOrSelfDestructingMessage_protectsEvenWithLockOffOrGrant() {
        XCTAssertTrue(ChatProtectionPolicy.isProtected(lockEnabled: false, peerGranted: nil, ephemeralTimerSeconds: 60))
        XCTAssertTrue(ChatProtectionPolicy.isProtected(lockEnabled: true, peerGranted: true, ephemeralTimerSeconds: 5))
        XCTAssertTrue(ChatProtectionPolicy.isProtected(lockEnabled: false, peerGranted: true, ephemeralTimerSeconds: nil,
                                                       selfDestructingMessage: true))
    }

    func test_viewOnceTimerMinusOne_protects() {
        XCTAssertTrue(ChatProtectionPolicy.isProtected(lockEnabled: false, peerGranted: true, ephemeralTimerSeconds: -1))
    }

    func test_outboundSelfDestructingPreview_isMaskedEvenWhenUnprotected() throws {
        let (store, id) = try makeStore(lockEnabled: false)
        store.recordNewMessage(conversationId: id, lastMessagePreview: "visto una volta",
                               lastActivity: Date(), incrementUnread: false, selfDestructing: true)
        XCTAssertEqual(store.loadConversations().first(where: { $0.id == id })?.lastMessagePreview, marker)
    }

    func test_lockPreferenceDefaultsToOn() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "test.chatprotection.\(UUID().uuidString)"))
        XCTAssertTrue(ChatProtectionPolicy.lockPreferenceEnabled(defaults))
        defaults.set(false, forKey: ChatProtectionPolicy.lockPreferenceKey)
        XCTAssertFalse(ChatProtectionPolicy.lockPreferenceEnabled(defaults))
    }

    // MARK: - Masking

    func test_displayPreview_masksProtectedText_andStoredMarker() {
        XCTAssertEqual(ChatProtectionPolicy.displayPreview("segreto", protected: true, placeholder: label), label)
        XCTAssertEqual(ChatProtectionPolicy.displayPreview(marker, protected: false, placeholder: label), label)
        XCTAssertEqual(ChatProtectionPolicy.displayPreview("ciao", protected: false, placeholder: label), "ciao")
        XCTAssertEqual(ChatProtectionPolicy.displayPreview("", protected: true, placeholder: label), "")
        XCTAssertNil(ChatProtectionPolicy.displayPreview(nil, protected: true, placeholder: label))
    }

    func test_storedPreview_isMarkerOnlyWhenProtectedAndEnabled() {
        XCTAssertEqual(ChatProtectionPolicy.storedPreview("segreto", protected: true), marker)
        XCTAssertEqual(ChatProtectionPolicy.storedPreview("ciao", protected: false), "ciao")
        ChatProtectionPolicy.maskStoredPreviews = false
        XCTAssertEqual(ChatProtectionPolicy.storedPreview("segreto", protected: true), "segreto")
    }

    // MARK: - Store boundary

    private func makeStore(lockEnabled: Bool, granted: Bool? = nil, timer: Int? = nil) throws -> (ConversationStore, UUID) {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "test.chatprotection.store.\(UUID().uuidString)"))
        defaults.set(lockEnabled, forKey: ChatProtectionPolicy.lockPreferenceKey)
        let store = ConversationStore(defaults: defaults)
        store.wipeAll()
        let id = UUID()
        store.upsertConversation(Conversation(
            id: id, peerUserId: "peer-1", peerDisplayName: "Peer", lastMessagePreview: nil,
            lastActivity: Date(timeIntervalSince1970: 1_745_000_000), unreadCount: 0, pinned: false,
            ephemeralTimerSeconds: timer, screenshotGrantedByPeer: granted))
        return (store, id)
    }

    private func inbound(_ id: UUID, _ text: String, viewOnce: Bool = false) -> Message {
        Message(id: UUID(), conversationId: id, direction: .incoming, plaintext: text,
                sentAt: Date(timeIntervalSince1970: 1_745_000_100), deliveredAt: Date(), readAt: nil,
                status: .delivered, senderUserId: "peer-1", serverMessageId: "srv-1", clientMsgId: "cmid-1",
                isViewOnce: viewOnce ? true : nil)
    }

    func test_inboundTextInProtectedConversation_isNotStoredAsPreview() throws {
        let (store, id) = try makeStore(lockEnabled: true)
        let msg = inbound(id, "testo riservato")
        store.recordInboundUserMessage(msg, preview: msg.plaintext, incrementUnread: true, kind: .text)
        let stored = store.loadConversations().first(where: { $0.id == id })?.lastMessagePreview
        XCTAssertEqual(stored, marker)
        XCTAssertNotEqual(stored, "testo riservato")
    }

    func test_outboundPreview_isMaskedInProtectedConversation() throws {
        let (store, id) = try makeStore(lockEnabled: true)
        store.recordNewMessage(conversationId: id, lastMessagePreview: "uscita riservata",
                               lastActivity: Date(), incrementUnread: false)
        XCTAssertEqual(store.loadConversations().first(where: { $0.id == id })?.lastMessagePreview, marker)
    }

    func test_unprotectedConversation_keepsItsPreview() throws {
        let (store, id) = try makeStore(lockEnabled: true, granted: true)
        let msg = inbound(id, "ciao")
        store.recordInboundUserMessage(msg, preview: msg.plaintext, incrementUnread: true, kind: .text)
        XCTAssertEqual(store.loadConversations().first(where: { $0.id == id })?.lastMessagePreview, "ciao")
    }

    func test_viewOnceMessage_isMaskedEvenWhenTheLockIsOff() throws {
        let (store, id) = try makeStore(lockEnabled: false)
        let msg = inbound(id, "una volta sola", viewOnce: true)
        store.recordInboundUserMessage(msg, preview: msg.plaintext, incrementUnread: true, kind: .text)
        XCTAssertEqual(store.loadConversations().first(where: { $0.id == id })?.lastMessagePreview, marker)
    }
}
