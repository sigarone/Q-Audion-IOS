import XCTest
@testable import QAudionApp

/// The queue the share extension writes and the app reads, and the rules around it.
final class ShareQueueTests: XCTestCase {

    private var root: URL!
    private var store: ShareQueueStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ShareQueueTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = ShareQueueStore(containerURL: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Writes a committed entry with one file and one text.
    @discardableResult
    private func commitEntry(peer: String = "peer-1", at now: Date = Date(), fileName: String = "photo.jpg") throws -> (id: String, folder: URL) {
        let began = try store.beginEntry(now: now)
        try Data("jpeg".utf8).write(to: began.folder.appendingPathComponent(fileName))
        let entry = ShareEntry(id: began.id, createdAt: now, peerUserId: peer, items: [
            ShareItem(kind: .image, fileName: fileName, displayName: fileName, byteCount: 4),
            ShareItem(kind: .text, text: "hello"),
        ])
        try store.commit(entry, in: began.folder)
        return began
    }

    // MARK: - Entries

    func testCommittedEntryIsPending() throws {
        let began = try commitEntry()
        let pending = store.pendingEntries()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.entry.id, began.id)
        XCTAssertEqual(pending.first?.entry.peerUserId, "peer-1")
        XCTAssertEqual(pending.first?.entry.items.count, 2)
    }

    func testEntryWithoutManifestIsNotPending() throws {
        let began = try store.beginEntry()
        try Data("x".utf8).write(to: began.folder.appendingPathComponent("a.bin"))
        XCTAssertTrue(store.pendingEntries().isEmpty)
    }

    func testOldestEntryComesFirst() throws {
        let now = Date()
        try commitEntry(peer: "newer", at: now)
        try commitEntry(peer: "older", at: now.addingTimeInterval(-60))
        XCTAssertEqual(store.pendingEntries(now: now).map(\.entry.peerUserId), ["older", "newer"])
    }

    func testExpiredEntryIsPurged() throws {
        let now = Date()
        try commitEntry(at: now.addingTimeInterval(-ShareLimits.entryLifetime - 10))
        XCTAssertTrue(store.pendingEntries(now: now).isEmpty)
    }

    func testInterruptedCopyIsPurgedAfterItsLifetime() throws {
        let began = try store.beginEntry(now: Date().addingTimeInterval(-ShareLimits.partialLifetime - 10))
        XCTAssertTrue(FileManager.default.fileExists(atPath: began.folder.path))
        store.purge()
        XCTAssertFalse(FileManager.default.fileExists(atPath: began.folder.path))
    }

    func testQueueIsLimited() throws {
        for _ in 0..<ShareLimits.maxQueuedEntries { try commitEntry() }
        XCTAssertThrowsError(try store.beginEntry()) { XCTAssertEqual($0 as? ShareQueueError, .queueFull) }
    }

    func testCommitRefusesEmptyAndOversizedShares() throws {
        let began = try store.beginEntry()
        XCTAssertThrowsError(try store.commit(ShareEntry(id: began.id, createdAt: Date(), peerUserId: "p", items: []), in: began.folder)) {
            XCTAssertEqual($0 as? ShareQueueError, .emptyShare)
        }
        let many = (0..<(ShareLimits.maxItems + 1)).map { _ in ShareItem(kind: .text, text: "x") }
        XCTAssertThrowsError(try store.commit(ShareEntry(id: began.id, createdAt: Date(), peerUserId: "p", items: many), in: began.folder)) {
            XCTAssertEqual($0 as? ShareQueueError, .tooManyItems)
        }
        let big = ShareItem(kind: .text, text: String(repeating: "a", count: ShareLimits.maxTextBytes + 1))
        XCTAssertThrowsError(try store.commit(ShareEntry(id: began.id, createdAt: Date(), peerUserId: "p", items: [big]), in: began.folder)) {
            XCTAssertEqual($0 as? ShareQueueError, .itemTooLarge)
        }
    }

    func testCommitRefusesAMissingFileAndAnUnsafeName() throws {
        let began = try store.beginEntry()
        let missing = ShareItem(kind: .file, fileName: "nothing.pdf", byteCount: 1)
        XCTAssertThrowsError(try store.commit(ShareEntry(id: began.id, createdAt: Date(), peerUserId: "p", items: [missing]), in: began.folder))
        let escaping = ShareItem(kind: .file, fileName: "../escape.pdf", byteCount: 1)
        XCTAssertThrowsError(try store.commit(ShareEntry(id: began.id, createdAt: Date(), peerUserId: "p", items: [escaping]), in: began.folder))
    }

    func testCommitRefusesAnInvalidDestination() throws {
        let began = try store.beginEntry()
        let entry = ShareEntry(id: began.id, createdAt: Date(), peerUserId: "../x", items: [ShareItem(kind: .text, text: "a")])
        XCTAssertThrowsError(try store.commit(entry, in: began.folder)) { XCTAssertEqual($0 as? ShareQueueError, .invalidDestination) }
    }

    func testEntryOfANewerFormatIsSkipped() throws {
        let began = try store.beginEntry()
        let entry = ShareEntry(version: 99, id: began.id, createdAt: Date(), peerUserId: "p", items: [ShareItem(kind: .text, text: "a")])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(entry).write(to: began.folder.appendingPathComponent("manifest.json"))
        XCTAssertTrue(store.pendingEntries().isEmpty)
    }

    // MARK: - Taking an entry

    func testTakeMovesTheFilesAndRemovesTheEntry() throws {
        let began = try commitEntry()
        let destination = root.appendingPathComponent("taken", isDirectory: true)
        let pending = try XCTUnwrap(store.pendingEntries().first)
        let plan = try XCTUnwrap(store.take(pending.entry, from: pending.folder, into: destination))
        XCTAssertEqual(plan.images, [destination.appendingPathComponent("photo.jpg")])
        XCTAssertEqual(plan.text, "hello")
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("photo.jpg").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: began.folder.path))
        XCTAssertTrue(store.pendingEntries().isEmpty)
    }

    func testPlanSortsItemsByKind() {
        let folder = URL(fileURLWithPath: "/tmp/f")
        let entry = ShareEntry(id: "e", createdAt: Date(), peerUserId: "p", items: [
            ShareItem(kind: .image, fileName: "a.png"), ShareItem(kind: .video, fileName: "b.mov"),
            ShareItem(kind: .file, fileName: "c.pdf"), ShareItem(kind: .url, text: "https://example.com"),
            ShareItem(kind: .text, text: "note"),
        ])
        let plan = ShareHandoffPlan.make(entry: entry, folder: folder)
        XCTAssertEqual(plan.images.map(\.lastPathComponent), ["a.png"])
        XCTAssertEqual(plan.videos.map(\.lastPathComponent), ["b.mov"])
        XCTAssertEqual(plan.files.map(\.lastPathComponent), ["c.pdf"])
        XCTAssertEqual(plan.text, "https://example.com\nnote")
        XCTAssertFalse(plan.isEmpty)
    }

    func testRemoveEverythingClearsQueueAndRecentChats() throws {
        try commitEntry()
        store.writeRecentChats([ShareRecentChat(peerUserId: "p", displayName: "Anna", lastActivity: Date())])
        store.removeEverything()
        XCTAssertTrue(store.pendingEntries().isEmpty)
        XCTAssertTrue(store.readRecentChats().isEmpty)
    }

    // MARK: - Recent chats

    func testRecentChatsRoundTripNewestFirstAndLimited() {
        let now = Date()
        let chats = (0..<30).map { ShareRecentChat(peerUserId: "p\($0)", displayName: "N\($0)", lastActivity: now.addingTimeInterval(Double($0))) }
        store.writeRecentChats(chats)
        let read = store.readRecentChats()
        XCTAssertEqual(read.count, ShareLimits.maxRecentChats)
        XCTAssertEqual(read.first?.peerUserId, "p29")
    }

    func testWritingNoChatsRemovesTheList() {
        store.writeRecentChats([ShareRecentChat(peerUserId: "p", displayName: "A", lastActivity: Date())])
        store.writeRecentChats([])
        XCTAssertTrue(store.readRecentChats().isEmpty)
    }

    func testWithoutAContainerNothingWorks() {
        let none = ShareQueueStore(containerURL: nil)
        XCTAssertTrue(none.readRecentChats().isEmpty)
        XCTAssertTrue(none.pendingEntries().isEmpty)
        XCTAssertThrowsError(try none.beginEntry()) { XCTAssertEqual($0 as? ShareQueueError, .noContainer) }
    }

    // MARK: - Rules

    func testFileNamesAreMadeSafe() {
        XCTAssertEqual(ShareRules.sanitizedFileName("../../etc/passwd", fallback: "f"), "passwd")
        XCTAssertEqual(ShareRules.sanitizedFileName("a\\b\\c.txt", fallback: "f"), "c.txt")
        XCTAssertEqual(ShareRules.sanitizedFileName(".hidden", fallback: "f"), "hidden")
        XCTAssertEqual(ShareRules.sanitizedFileName("..", fallback: "f"), "f")
        XCTAssertEqual(ShareRules.sanitizedFileName("", fallback: "f"), "f")
        let long = String(repeating: "a", count: 300) + ".pdf"
        let cut = ShareRules.sanitizedFileName(long, fallback: "f")
        XCTAssertLessThanOrEqual(cut.count, 100)
        XCTAssertTrue(cut.hasSuffix(".pdf"))
    }

    func testWebLinksAreRecognised() {
        XCTAssertTrue(ShareRules.isWebLink("https://example.com/a?b=1"))
        XCTAssertTrue(ShareRules.isWebLink("  http://example.com "))
        XCTAssertFalse(ShareRules.isWebLink("example.com"))
        XCTAssertFalse(ShareRules.isWebLink("file:///tmp/a"))
        XCTAssertFalse(ShareRules.isWebLink("two words https://example.com"))
    }

    func testTextIsClippedOnACharacterBoundary() {
        let text = String(repeating: "é", count: ShareLimits.maxTextBytes)
        let clipped = ShareRules.clippedText(text)
        XCTAssertLessThanOrEqual(clipped.utf8.count, ShareLimits.maxTextBytes)
        XCTAssertEqual(ShareRules.clippedText("short"), "short")
    }

    func testFileKindFromTypeIdentifiers() {
        XCTAssertEqual(ShareRules.fileKind(forTypeIdentifiers: ["public.jpeg", "public.image"]), .image)
        XCTAssertEqual(ShareRules.fileKind(forTypeIdentifiers: ["com.apple.quicktime-movie"]), .video)
        XCTAssertEqual(ShareRules.fileKind(forTypeIdentifiers: ["com.adobe.pdf"]), .file)
        XCTAssertNil(ShareRules.fileKind(forTypeIdentifiers: []))
        XCTAssertNil(ShareRules.fileKind(forTypeIdentifiers: ["not a type"]))
    }

    // MARK: - Handoff policy

    func testHandoffAppliesOnlyToItsChatAccountAndWhileFresh() {
        let now = Date()
        let plan = ShareHandoffPlan(images: [], videos: [], files: [], text: "x")
        let handoff = ShareHandoff(peerUserId: "p", accountId: "me", plan: plan, createdAt: now, folder: root)
        XCTAssertTrue(ShareHandoffPolicy.applies(handoff, peerUserId: "p", accountId: "me", now: now))
        XCTAssertFalse(ShareHandoffPolicy.applies(handoff, peerUserId: "other", accountId: "me", now: now))
        XCTAssertFalse(ShareHandoffPolicy.applies(handoff, peerUserId: "p", accountId: "someone", now: now))
        XCTAssertFalse(ShareHandoffPolicy.applies(handoff, peerUserId: "p", accountId: "me", now: now.addingTimeInterval(11 * 60)))
        XCTAssertFalse(ShareHandoffPolicy.applies(nil, peerUserId: "p", accountId: "me", now: now))
    }

    // MARK: - Hardening

    func testEntryWithANonUUIDIdIsSkipped() throws {
        let began = try store.beginEntry()
        let entry = ShareEntry(id: "../evil", createdAt: Date(), peerUserId: "p", items: [ShareItem(kind: .text, text: "a")])
        try store.commit(entry, in: began.folder)
        XCTAssertTrue(store.pendingEntries().isEmpty)
    }

    func testCommitRefusesALink() throws {
        let began = try store.beginEntry()
        let target = root.appendingPathComponent("target.txt")
        try Data("s".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: began.folder.appendingPathComponent("link.txt"), withDestinationURL: target)
        let entry = ShareEntry(id: began.id, createdAt: Date(), peerUserId: "p", items: [ShareItem(kind: .file, fileName: "link.txt", byteCount: 1)])
        XCTAssertThrowsError(try store.commit(entry, in: began.folder))
    }

    func testFileReplacedByALinkAfterCommitIsNotPickedUp() throws {
        let began = try commitEntry()
        let target = root.appendingPathComponent("target.txt")
        try Data("s".utf8).write(to: target)
        let file = began.folder.appendingPathComponent("photo.jpg")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        XCTAssertTrue(store.pendingEntries().isEmpty)
    }

    func testShareAboveTheTotalLimitIsRefused() throws {
        let began = try store.beginEntry()
        var items: [ShareItem] = []
        for name in ["a.bin", "b.bin", "c.bin"] {
            try Data("x".utf8).write(to: began.folder.appendingPathComponent(name))
            items.append(ShareItem(kind: .file, fileName: name, byteCount: ShareLimits.maxItemBytes))
        }
        XCTAssertThrowsError(try store.commit(ShareEntry(id: began.id, createdAt: Date(), peerUserId: "p", items: items), in: began.folder)) {
            XCTAssertEqual($0 as? ShareQueueError, .itemTooLarge)
        }
    }

    func testQueueAboveTheTotalLimitTakesNoMoreShares() throws {
        for _ in 0..<2 {
            let began = try store.beginEntry()
            var items: [ShareItem] = []
            for name in ["a.bin", "b.bin"] {
                try Data("x".utf8).write(to: began.folder.appendingPathComponent(name))
                items.append(ShareItem(kind: .file, fileName: name, byteCount: ShareLimits.maxItemBytes))
            }
            try store.commit(ShareEntry(id: began.id, createdAt: Date(), peerUserId: "p", items: items), in: began.folder)
        }
        XCTAssertThrowsError(try store.beginEntry()) { XCTAssertEqual($0 as? ShareQueueError, .queueFull) }
    }

    func testHiddenRecentsShowNoNamesAndClearWithEverything() {
        store.writeRecentChats([ShareRecentChat(peerUserId: "p", displayName: "Anna", lastActivity: Date())])
        XCTAssertEqual(store.readRecentChats().count, 1)
        store.setRecentsHidden(true)
        XCTAssertTrue(store.recentsHidden)
        XCTAssertTrue(store.readRecentChats().isEmpty)
        store.removeEverything()
        XCTAssertFalse(store.recentsHidden)
    }

    func testSweepSparesTheFoldersInUse() {
        let now = Date()
        let old = now.addingTimeInterval(-3600)
        let tmp = FileManager.default.temporaryDirectory
        let pending = tmp.appendingPathComponent("shared-pending", isDirectory: true)
        let active = tmp.appendingPathComponent("shared-active", isDirectory: true)
        let other = tmp.appendingPathComponent("shared-other", isDirectory: true)
        let protected: [URL?] = [pending, active]
        XCTAssertFalse(ShareHandoffPolicy.shouldSweep(folder: pending, created: old, now: now, protectedFolders: protected))
        XCTAssertFalse(ShareHandoffPolicy.shouldSweep(folder: active, created: old, now: now, protectedFolders: protected))
        XCTAssertTrue(ShareHandoffPolicy.shouldSweep(folder: other, created: old, now: now, protectedFolders: protected))
        XCTAssertFalse(ShareHandoffPolicy.shouldSweep(folder: other, created: now.addingTimeInterval(-60), now: now, protectedFolders: protected))
        XCTAssertFalse(ShareHandoffPolicy.shouldSweep(folder: other, created: nil, now: now, protectedFolders: protected))
        XCTAssertTrue(ShareHandoffPolicy.shouldSweep(folder: active, created: old, now: now, protectedFolders: [nil, nil]))
    }

    func testHandoffIsStaleWhenOldOrOfAnotherAccount() {
        let now = Date()
        let plan = ShareHandoffPlan(images: [], videos: [], files: [], text: "x")
        let handoff = ShareHandoff(peerUserId: "p", accountId: "me", plan: plan, createdAt: now, folder: root)
        XCTAssertFalse(ShareHandoffPolicy.isStale(handoff, accountId: "me", now: now.addingTimeInterval(60)))
        XCTAssertTrue(ShareHandoffPolicy.isStale(handoff, accountId: "me", now: now.addingTimeInterval(11 * 60)))
        XCTAssertTrue(ShareHandoffPolicy.isStale(handoff, accountId: "other", now: now))
    }
}
