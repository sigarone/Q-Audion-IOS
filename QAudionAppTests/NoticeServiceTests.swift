import XCTest
@testable import QAudionApp
import QAudionEngine

/// The logic of the service-notice inbox that needs no network or key:
/// which envelopes the inbox shows (expiry, undecryptable ones, the read state
/// carried between polls), the unread count that goes with the list, and the
/// reset when the account leaves. The transport and the decryption itself are
/// not exercised here.
///
/// Wired into CI: on the include list of `QAudionApp/project-apptests.yml` and
/// in the `-only-testing` list of `.github/workflows/ios-app-tests.yml`.
final class NoticeServiceTests: XCTestCase {

    private typealias Envelope = NoticeService.NoticeEnvelope
    private typealias Notice = NoticeService.ServiceNotice

    private func envelope(_ id: String, expiresMs: Int64) -> Envelope {
        Envelope(
            id: id, kind: "info", priority: "normal", title: "title-" + id,
            ephemeral_pub: "", ciphertext: "", created_ms: 1_000, expires_ms: expiresMs)
    }

    private func notice(_ id: String, read: Bool) -> Notice {
        Notice(
            id: id, kind: "info", priority: "normal", title: "title-" + id, body: "body-" + id,
            createdMs: 1_000, expiresMs: 9_000_000, read: read)
    }

    // MARK: - expiry

    /// An envelope is live only while `expires_ms` is strictly after now: at the
    /// boundary it is already gone, a millisecond earlier it still shows.
    @MainActor
    func test_expiredEnvelopesAreDropped_andTheBoundaryCountsAsExpired() {
        let out = NoticeService.assemble(
            envelopes: [
                envelope("live", expiresMs: 5_001),
                envelope("edge", expiresMs: 5_000),
                envelope("gone", expiresMs: 4_999),
            ],
            nowMs: 5_000,
            previous: [],
            decrypt: { _ in "plain" })
        XCTAssertEqual(out.map(\.id), ["live"])
    }

    @MainActor
    func test_anEnvelopeThatCannotBeDecryptedIsDroppedWithoutLosingTheOthers() {
        let out = NoticeService.assemble(
            envelopes: [
                envelope("a", expiresMs: 9_000),
                envelope("broken", expiresMs: 9_000),
                envelope("c", expiresMs: 9_000),
            ],
            nowMs: 1,
            previous: [],
            decrypt: { env in
                if env.id == "broken" { return nil }
                return "plain-" + env.id
            })
        XCTAssertEqual(out.map(\.id), ["a", "c"])
        XCTAssertEqual(out.map(\.body), ["plain-a", "plain-c"])
    }

    // MARK: - read state across polls

    /// A re-poll must not un-read what the user already opened, and a notice
    /// seen for the first time starts unread. Matched by id, not by position.
    @MainActor
    func test_readStateIsCarriedOverByID_andNewNoticesStartUnread() {
        let out = NoticeService.assemble(
            envelopes: [
                envelope("fresh", expiresMs: 9_000),
                envelope("seen", expiresMs: 9_000),
                envelope("unseen", expiresMs: 9_000),
            ],
            nowMs: 1,
            previous: [notice("unseen", read: false), notice("seen", read: true)],
            decrypt: { _ in "plain" })
        XCTAssertEqual(out.map(\.id), ["fresh", "seen", "unseen"])
        XCTAssertEqual(out.map(\.read), [false, true, false])
    }

    /// A duplicate id in the previous list must never crash the poll.
    @MainActor
    func test_aDuplicateIDInThePreviousListDoesNotCrashThePoll() {
        let out = NoticeService.assemble(
            envelopes: [envelope("dup", expiresMs: 9_000)],
            nowMs: 1,
            previous: [notice("dup", read: false), notice("dup", read: true)],
            decrypt: { _ in "plain" })
        XCTAssertEqual(out.count, 1)
    }

    // MARK: - published list and unread count

    @MainActor
    func test_publishSetsTheUnreadCountFromTheList() {
        let service = NoticeService()
        service.publish(
            [notice("a", read: false), notice("b", read: true), notice("c", read: false)],
            startedUnder: service.currentGeneration)
        XCTAssertEqual(service.notices.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(service.unreadCount, 2)
    }

    // MARK: - the account leaves

    /// The service is a singleton polled from boot: the next account on the
    /// device must not see the previous one's notices or its unread dot.
    @MainActor
    func test_resetForAccountChangeEmptiesTheInboxAndTheUnreadCount() {
        let service = NoticeService()
        service.publish(
            [notice("a", read: false), notice("b", read: false)],
            startedUnder: service.currentGeneration)
        XCTAssertEqual(service.unreadCount, 2)

        service.resetForAccountChange()
        XCTAssertTrue(service.notices.isEmpty)
        XCTAssertEqual(service.unreadCount, 0)
    }

    /// A poll already in flight when the account leaves finishes afterwards:
    /// its result belongs to the old account and must not come back. A poll
    /// that starts after the reset publishes normally.
    @MainActor
    func test_aPollStartedBeforeTheResetCannotPutTheOldNoticesBack() {
        let service = NoticeService()
        let startedBeforeReset = service.currentGeneration
        service.resetForAccountChange()

        service.publish([notice("old-account", read: false)], startedUnder: startedBeforeReset)
        XCTAssertTrue(service.notices.isEmpty)
        XCTAssertEqual(service.unreadCount, 0)

        service.publish([notice("new-account", read: false)], startedUnder: service.currentGeneration)
        XCTAssertEqual(service.notices.map(\.id), ["new-account"])
        XCTAssertEqual(service.unreadCount, 1)
    }
}
