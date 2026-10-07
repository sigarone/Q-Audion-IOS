import XCTest
import CryptoKit
@testable import QAudionEngine

/// The hardened identity of a source (WIRE_SPEC 12.8 asks for the size and the modification time; the pipeline also keeps the time to the
/// nanosecond, the file number, the creation time and a SHA-256 of the first and last 64 KiB). What it makes visible, what it does not,
/// and how the pipeline uses it before it seals anything.
final class FileV2SendIdentityTests: XCTestCase {

    private let sample = FileV2SourceIdentity.sampleLength

    private func sequentialRig() throws -> SendRig {
        let rig = try SendRig(self)
        rig.fake.maxPartsInFlight = 1
        return rig
    }

    private func makeFile(_ count: Int, name: String = "source.bin") throws -> URL {
        let directory = try FileV2TestSupport.makeTempDirectory(for: self)
        let url = directory.appendingPathComponent(name)
        try Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ ($0 >> 8)) }).write(to: url)
        return url
    }

    /// Writes `byte` at `offset` in place, then puts the modification time back to the nanosecond.
    private func edit(_ url: URL, at offset: Int, with byte: UInt8, restoringTimeTo nanoseconds: Int64) throws {
        let handle = try FileHandle(forUpdating: url)
        try handle.seek(toOffset: UInt64(offset))
        try handle.write(contentsOf: Data([byte]))
        try handle.close()
        try SendFileTimes.restoreModificationTime(ofPath: url.path, toNanoseconds: nanoseconds)
    }

    // MARK: The value

    func testEveryMemberOfTheIdentityIsComparedAndAMemberOnlyOneSideHasIsAChange() {
        let base = FileV2SourceIdentity(locator: "/a/b", size: 10, modifiedMs: 5, modifiedNs: 5_000_123, fileNumber: 9, createdMs: 3,
                                        headDigest: Data([1]), tailDigest: Data([2]))
        XCTAssertTrue(base.isUnchanged(comparedTo: FileV2SourceIdentity(locator: "/elsewhere", size: 10, modifiedMs: 5, modifiedNs: 5_000_123,
                                                                        fileNumber: 9, createdMs: 3, headDigest: Data([1]), tailDigest: Data([2]))),
                      "the locator is not compared")
        let changed: [(String, FileV2SourceIdentity)] = [
            ("size", FileV2SourceIdentity(locator: "/a/b", size: 11, modifiedMs: 5, modifiedNs: 5_000_123, fileNumber: 9, createdMs: 3,
                                          headDigest: Data([1]), tailDigest: Data([2]))),
            ("modifiedMs", FileV2SourceIdentity(locator: "/a/b", size: 10, modifiedMs: 6, modifiedNs: 5_000_123, fileNumber: 9, createdMs: 3,
                                                headDigest: Data([1]), tailDigest: Data([2]))),
            ("modifiedNs", FileV2SourceIdentity(locator: "/a/b", size: 10, modifiedMs: 5, modifiedNs: 5_000_124, fileNumber: 9, createdMs: 3,
                                                headDigest: Data([1]), tailDigest: Data([2]))),
            ("fileNumber", FileV2SourceIdentity(locator: "/a/b", size: 10, modifiedMs: 5, modifiedNs: 5_000_123, fileNumber: 10, createdMs: 3,
                                                headDigest: Data([1]), tailDigest: Data([2]))),
            ("createdMs", FileV2SourceIdentity(locator: "/a/b", size: 10, modifiedMs: 5, modifiedNs: 5_000_123, fileNumber: 9, createdMs: 4,
                                               headDigest: Data([1]), tailDigest: Data([2]))),
            ("headDigest", FileV2SourceIdentity(locator: "/a/b", size: 10, modifiedMs: 5, modifiedNs: 5_000_123, fileNumber: 9, createdMs: 3,
                                                headDigest: Data([9]), tailDigest: Data([2]))),
            ("tailDigest", FileV2SourceIdentity(locator: "/a/b", size: 10, modifiedMs: 5, modifiedNs: 5_000_123, fileNumber: 9, createdMs: 3,
                                                headDigest: Data([1]), tailDigest: Data([9])))
        ]
        for (member, other) in changed {
            XCTAssertFalse(base.isUnchanged(comparedTo: other), "\(member) differs")
            XCTAssertFalse(other.isUnchanged(comparedTo: base), "\(member) differs (the other way)")
        }
        // A member that one side holds and the other does not cannot be verified: it is a change, whichever side lacks it.
        let bare = FileV2SourceIdentity(locator: "/a/b", size: 10, modifiedMs: 5)
        XCTAssertFalse(base.isUnchanged(comparedTo: bare))
        XCTAssertFalse(bare.isUnchanged(comparedTo: base))
        XCTAssertTrue(bare.isUnchanged(comparedTo: FileV2SourceIdentity(locator: "/x", size: 10, modifiedMs: 5)),
                      "a provider that gives only a size and a time is compared on those")
    }

    func testTheIdentityPrintsOnlyTheSizeAndSurvivesTheJournalsJSON() throws {
        let identity = FileV2SourceIdentity(locator: "/private/var/Containers/holiday.mov", size: 123_456, modifiedMs: 5, modifiedNs: 5_000_123,
                                            fileNumber: 987_654_321, createdMs: 3, headDigest: Data(repeating: 0xAB, count: 32),
                                            tailDigest: Data(repeating: 0xCD, count: 32))
        XCTAssertEqual(identity.description, "FileV2SourceIdentity(size=123456)")
        let printed = SendStoreFixtures.printed(identity)
        for secret in ["holiday", "/private", "987654321", Data(repeating: 0xAB, count: 32).base64EncodedString()] {
            XCTAssertFalse(printed.contains(secret), secret)
        }
        let decoded = try JSONDecoder().decode(FileV2SourceIdentity.self, from: try JSONEncoder().encode(identity))
        XCTAssertEqual(decoded, identity)

        // A journal that has none of the new members (made before them) decodes with them missing, and that is a change.
        let old = Data(#"{"locator":"/a","size":10,"modifiedMs":5}"#.utf8)
        let legacy = try JSONDecoder().decode(FileV2SourceIdentity.self, from: old)
        XCTAssertNil(legacy.headDigest)
        XCTAssertFalse(legacy.isUnchanged(comparedTo: FileV2SourceIdentity(locator: "/a", size: 10, modifiedMs: 5, headDigest: Data([1]))))
    }

    // MARK: A file

    func testAFileSourceReadsTheHardenedIdentityFromTheFileItself() throws {
        let url = try makeFile(300 * 1024)
        let bytes = [UInt8](try Data(contentsOf: url))
        let identity = try FileV2FileSource(url: url).currentIdentity()
        XCTAssertEqual(identity.size, 300 * 1024)
        XCTAssertEqual(identity.headDigest, Data(SHA256.hash(data: bytes.prefix(sample))), "the first 64 KiB")
        XCTAssertEqual(identity.tailDigest, Data(SHA256.hash(data: bytes.suffix(sample))), "the last 64 KiB")
        XCTAssertNotEqual(identity.headDigest, identity.tailDigest)
        XCTAssertNotNil(identity.fileNumber)
        let nanoseconds = try XCTUnwrap(identity.modifiedNs)
        XCTAssertEqual(identity.modifiedMs, nanoseconds / 1_000_000, "one time, read at two resolutions")
        #if canImport(Darwin)
        XCTAssertNotNil(identity.createdMs)
        #else
        XCTAssertNil(identity.createdMs, "Linux has no creation time in stat")
        #endif
        XCTAssertEqual(try FileV2FileSource(url: url).currentIdentity(), identity, "reading it twice gives the same")
    }

    func testAFileSmallerThanTheSampleHasTheSameHeadAndTailAndAnEmptyOneHasTheDigestOfNothing() throws {
        let url = try makeFile(10)
        let bytes = [UInt8](try Data(contentsOf: url))
        let identity = try FileV2FileSource(url: url).currentIdentity()
        XCTAssertEqual(identity.headDigest, Data(SHA256.hash(data: bytes)))
        XCTAssertEqual(identity.tailDigest, identity.headDigest)

        let empty = try makeFile(0, name: "empty.bin")
        let emptyIdentity = try FileV2FileSource(url: empty).currentIdentity()
        XCTAssertEqual(emptyIdentity.size, 0)
        XCTAssertEqual(emptyIdentity.headDigest, Data(SHA256.hash(data: [UInt8]())))
    }

    func testAFileThatIsGoneOrIsNotARegularFileHasNoIdentity() throws {
        let url = try makeFile(10)
        try FileManager.default.removeItem(at: url)
        XCTAssertThrowsError(try FileV2FileSource(url: url).currentIdentity()) { XCTAssertEqual($0 as? FileV2SendSourceError, .unavailable) }
        XCTAssertThrowsError(try FileV2FileSource(url: url.deletingLastPathComponent()).currentIdentity(), "a directory is not a source") {
            XCTAssertEqual($0 as? FileV2SendSourceError, .unavailable)
        }
    }

    func testAnEditAtTheStartOrTheEndWithTheTimeRestoredToTheNanosecondIsSeenByTheSamples() throws {
        let url = try makeFile(300 * 1024)
        let before = try FileV2FileSource(url: url).currentIdentity()
        let nanoseconds = try XCTUnwrap(before.modifiedNs)
        let original = [UInt8](try Data(contentsOf: url))

        try edit(url, at: 5, with: original[5] ^ 0xFF, restoringTimeTo: nanoseconds)
        var now = try FileV2FileSource(url: url).currentIdentity()
        XCTAssertEqual(now.size, before.size)
        XCTAssertEqual(now.modifiedNs, before.modifiedNs, "the time is exactly what it was")
        XCTAssertEqual(now.fileNumber, before.fileNumber)
        XCTAssertNotEqual(now.headDigest, before.headDigest)
        XCTAssertEqual(now.tailDigest, before.tailDigest)
        XCTAssertFalse(now.isUnchanged(comparedTo: before), "an edit in the first 64 KiB is seen")
        try edit(url, at: 5, with: original[5], restoringTimeTo: nanoseconds)
        XCTAssertTrue(try FileV2FileSource(url: url).currentIdentity().isUnchanged(comparedTo: before), "put back, it is the same file again")

        try edit(url, at: original.count - 5, with: original[original.count - 5] ^ 0xFF, restoringTimeTo: nanoseconds)
        now = try FileV2FileSource(url: url).currentIdentity()
        XCTAssertEqual(now.headDigest, before.headDigest)
        XCTAssertNotEqual(now.tailDigest, before.tailDigest)
        XCTAssertFalse(now.isUnchanged(comparedTo: before), "an edit in the last 64 KiB is seen")
    }

    func testAnEditInTheMiddleWithTheTimeRestoredIsTheCaseNoSampleSeesAndTheLedgerIsTheLastDefence() throws {
        let url = try makeFile(300 * 1024)
        let before = try FileV2FileSource(url: url).currentIdentity()
        let original = [UInt8](try Data(contentsOf: url))
        try edit(url, at: 150 * 1024, with: original[150 * 1024] ^ 0xFF, restoringTimeTo: try XCTUnwrap(before.modifiedNs))
        let now = try FileV2FileSource(url: url).currentIdentity()
        XCTAssertTrue(now.isUnchanged(comparedTo: before),
                      "this is the residual case the documentation names: the nonce rule's ledger catches it for a chunk that was sealed before")
        XCTAssertNotEqual([UInt8](try Data(contentsOf: url)), original)
    }

    func testATimeRestoredOnlyToTheMillisecondIsSeenByTheNanosecondTime() throws {
        let url = try makeFile(70 * 1024)
        let before = try FileV2FileSource(url: url).currentIdentity()
        let nanoseconds = try XCTUnwrap(before.modifiedNs)
        // The same millisecond, another nanosecond: what a tool that keeps times to the millisecond (or a Date) puts back.
        let sameMillisecond = nanoseconds - nanoseconds % 1_000_000 + (nanoseconds % 1_000_000 + 1) % 1_000_000
        try SendFileTimes.restoreModificationTime(ofPath: url.path, toNanoseconds: sameMillisecond)
        let now = try FileV2FileSource(url: url).currentIdentity()
        XCTAssertEqual(now.modifiedMs, before.modifiedMs, "the millisecond time cannot tell")
        XCTAssertNotEqual(now.modifiedNs, before.modifiedNs)
        XCTAssertFalse(now.isUnchanged(comparedTo: before))
    }

    func testAFileReplacedByAnotherWithTheSameContentAndTimesHasAnotherFileNumber() throws {
        let url = try makeFile(70 * 1024)
        let before = try FileV2FileSource(url: url).currentIdentity()
        // An editor that saves atomically: the new content (here the same) goes to a file of its own, which then replaces the old one.
        let replacement = url.deletingLastPathComponent().appendingPathComponent("replacement.bin")
        try Data(contentsOf: url).write(to: replacement)
        try SendFileTimes.restoreModificationTime(ofPath: replacement.path, toNanoseconds: try XCTUnwrap(before.modifiedNs))
        XCTAssertEqual(rename(replacement.path, url.path), 0, "an atomic replace of the name")
        let now = try FileV2FileSource(url: url).currentIdentity()
        XCTAssertEqual(now.size, before.size)
        XCTAssertEqual(now.modifiedNs, before.modifiedNs)
        XCTAssertEqual(now.headDigest, before.headDigest)
        XCTAssertNotEqual(now.fileNumber, before.fileNumber, "another file")
        XCTAssertFalse(now.isUnchanged(comparedTo: before))
    }

    // MARK: What the pipeline does with it

    /// Part 1 of a three-part source that gives the hardened identity is sealed (its tags journaled) and the process dies before its PUT.
    private func crashedBeforeThePutOfPartOne(_ rig: SendRig, _ source: GeneratedSource, id: String) async throws {
        rig.server.setCrash(RecordingServer.CrashPlan(op: .putPart, call: 1, applyEffect: false))
        let first = await (try rig.makePipeline()).send(rig.makeRequest(source, id: id))
        XCTAssertEqual(first, .interrupted)
        rig.server.revive()
    }

    func testTheJournalKeepsTheHardenedIdentityOfTheSource() async throws {
        let rig = try sequentialRig()
        let source = GeneratedSource(size: SendTestSizes.threeParts, fingerprint: true)
        try await crashedBeforeThePutOfPartOne(rig, source, id: "kept-identity")
        let stored = try rig.makeStore().load("kept-identity").begin.source
        XCTAssertEqual(stored, try source.currentIdentity())
        XCTAssertNotNil(stored.headDigest)
        XCTAssertNotNil(stored.tailDigest)
        XCTAssertNotNil(stored.fileNumber)
        XCTAssertNotNil(stored.modifiedNs)
    }

    func testAnEditOfTheFirstChunkWithTheSameSizeAndTimeIsCaughtBeforeAnythingIsSealed() async throws {
        let rig = try sequentialRig()
        let source = GeneratedSource(size: SendTestSizes.threeParts, fingerprint: true)
        try await crashedBeforeThePutOfPartOne(rig, source, id: "head-edit")
        let readsBefore = source.readCount
        source.mutate(chunk: 0)
        let result = await (try rig.makePipeline()).resume(transferID: "head-edit")
        assertSendFailure(result, .sourceChanged)
        XCTAssertEqual(source.readCount, readsBefore, "the source was not read: rule 1 stopped it before anything was sealed")
        XCTAssertEqual(rig.server.puts.map { $0.part }, [0])
        XCTAssertEqual(rig.fake.objectCount, 0)
        try rig.assertNothingIsLeftBehind()
    }

    func testAnEditOfTheLastChunkIsCaughtByTheIdentityEvenThoughNoTagOfItWasEverJournaled() async throws {
        let rig = try sequentialRig()
        let source = GeneratedSource(size: SendTestSizes.threeParts, fingerprint: true)
        try await crashedBeforeThePutOfPartOne(rig, source, id: "tail-edit")
        let readsBefore = source.readCount
        source.flipByte(at: source.size - 10)          // the last chunk: the ledger holds no tag of it, a size-and-time identity would not care
        let result = await (try rig.makePipeline()).resume(transferID: "tail-edit")
        assertSendFailure(result, .sourceChanged)
        XCTAssertEqual(source.readCount, readsBefore)
        XCTAssertEqual(rig.fake.objectCount, 0)
        try rig.assertNothingIsLeftBehind()
    }

    func testAnEditInTheMiddleOfASourceThatGivesTheHardenedIdentityStillReachesTheLedger() async throws {
        let rig = try sequentialRig()
        let source = GeneratedSource(size: SendTestSizes.threeParts, fingerprint: true)
        try await crashedBeforeThePutOfPartOne(rig, source, id: "middle-edit")
        let identityBefore = try source.currentIdentity()
        let readsBefore = source.readCount
        source.mutate(chunk: 9)
        XCTAssertTrue(try source.currentIdentity().isUnchanged(comparedTo: identityBefore), "the middle is not sampled")
        let result = await (try rig.makePipeline()).resume(transferID: "middle-edit")
        assertSendFailure(result, .sourceChanged)
        XCTAssertGreaterThan(source.readCount, readsBefore, "this time the part WAS sealed again, and its tag did not match")
        XCTAssertEqual(rig.server.puts.map { $0.part }, [0], "the changed chunk was never transmitted")
        rig.assertNoChunkWasEverTransmittedWithADifferentTag()
        try rig.assertNothingIsLeftBehind()
    }

    func testAChangeOfTheNanosecondOrOfTheFileNumberCancelsTheResume() async throws {
        for change in ["nanosecond", "file number"] {
            let rig = try sequentialRig()
            let source = GeneratedSource(size: SendTestSizes.threeParts, fingerprint: true)
            try await crashedBeforeThePutOfPartOne(rig, source, id: "identity-change")
            if change == "nanosecond" { source.touchByANanosecond() } else { source.replaceFile() }
            let result = await (try rig.makePipeline()).resume(transferID: "identity-change")
            assertSendFailure(result, .sourceChanged)
            XCTAssertEqual(rig.fake.objectCount, 0, change)
            XCTAssertEqual(rig.telemetry.count { $0 == .contentChanged }, 1, change)
            try rig.assertNothingIsLeftBehind()
        }
    }

    func testAnEditOfTheFirstChunkWhileARunIsInProgressIsCaughtBeforeTheNextPart() async throws {
        let rig = try sequentialRig()
        let source = GeneratedSource(size: SendTestSizes.threeParts, fingerprint: true)
        rig.server.setHook { op, call in
            if op == .putPart && call == 1 { source.mutate(chunk: 0) }          // while part 1 is on the wire
        }
        let result = await (try rig.makePipeline()).send(rig.makeRequest(source, id: "moving-head"))
        assertSendFailure(result, .sourceChanged)
        XCTAssertEqual(rig.server.puts.map { $0.part }, [0, 1], "no part is sealed after the change was seen")
        XCTAssertEqual(rig.fake.objectCount, 0)
        try rig.assertNothingIsLeftBehind()
    }

    func testASourceThatGivesTheHardenedIdentityStillSendsAndItsBlobIsAOneShotEncryption() async throws {
        let rig = try sequentialRig()
        let source = GeneratedSource(size: SendTestSizes.threeParts, fingerprint: true)
        let result = await (try rig.makePipeline()).send(rig.makeRequest(source, id: "fingerprinted"))
        XCTAssertEqual(result, .sentOk)
        try rig.assertBlobEqualsOneShot(descriptor: try rig.lastDescriptor(), source: source)
        try rig.assertNothingIsLeftBehind()
    }
}
