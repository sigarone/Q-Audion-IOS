import XCTest
@testable import QAudionEngine

/// The vocabulary of the pipeline: how a taxonomy value of the transport layer becomes the reason the user interface acts on, which
/// failures keep a transfer's state and which end it, and what a state says about itself.
final class FileV2SendTypesTests: XCTestCase {

    func testEveryTransportErrorHasAReasonWithTheSameMeaning() {
        let expected: [FileV2TransferError: FileV2SendFailure.Reason] = [
            .entitlement: .entitlement, .quota: .quota, .serverFull: .serverFull, .rateLimited: .rateLimited, .network: .network,
            .auth: .auth, .noSpace: .storage, .sourceChanged: .sourceChanged, .badRequest: .badRequest,
            .announceNotSent: .announceNotSent, .descriptorTooLarge: .descriptorTooLarge
        ]
        XCTAssertEqual(Set(expected.keys), Set(FileV2TransferError.allCases), "every taxonomy value is mapped")
        for (error, reason) in expected {
            let failure = FileV2SendFailure(transfer: error)
            XCTAssertEqual(failure.reason, reason)
            XCTAssertEqual(failure.transferError, error)
        }
    }

    func testTheReasonsAreFixedWordsOfLowercaseLettersAndUnderscores() {
        for reason in FileV2SendFailure.Reason.allCases {
            let bytes = Array(reason.rawValue.utf8)
            XCTAssertFalse(bytes.isEmpty)
            XCTAssertTrue(bytes.allSatisfy { ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x5F }, reason.rawValue)
        }
        XCTAssertEqual(Set(FileV2SendFailure.Reason.allCases.map { $0.rawValue }).count, FileV2SendFailure.Reason.allCases.count)
    }

    func testOnlyAPauseOrARefusalThatTheUserCanFixKeepsTheState() {
        let keeps: Set<FileV2SendFailure.Reason> = [.network, .rateLimited, .auth, .entitlement, .serverFull, .userRemedy, .busy,
                                                    .announceNotSent, .storage]
        for reason in FileV2SendFailure.Reason.allCases {
            XCTAssertEqual(FileV2SendFailure(reason).keepsState, keeps.contains(reason), reason.rawValue)
        }
        // A source change, a lost state, a cancel and a bad request end the transfer: its object and its secrets go.
        for ended in [FileV2SendFailure.Reason.sourceChanged, .stateLost, .cancelled, .badRequest, .descriptorTooLarge] {
            XCTAssertFalse(FileV2SendFailure(ended).keepsState)
        }
    }

    func testAFailurePrintsItsReasonAndNothingElse() {
        let failure = FileV2SendFailure(transfer: .quota, details: FileV2ErrorDetails(used: 123_456_789, limit: 987_654_321),
                                        code: "quota_exceeded")
        XCTAssertEqual(failure.description, "FileV2SendFailure(quota)")
        XCTAssertEqual(failure.details?.used, 123_456_789, "the numbers a user interface shows stay available")
    }

    func testTheTerminalStatesAreTheOnesThatEndATransfer() {
        let progress = FileV2SendProgress(partsDone: 1, partsTotal: 3, bytesDone: 10, bytesTotal: 30)
        XCTAssertFalse(FileV2SendState.preparing.isTerminal)
        XCTAssertFalse(FileV2SendState.sealing.isTerminal)
        XCTAssertFalse(FileV2SendState.uploading(progress).isTerminal)
        XCTAssertFalse(FileV2SendState.completing.isTerminal)
        XCTAssertFalse(FileV2SendState.announcing.isTerminal)
        XCTAssertTrue(FileV2SendState.sentOk.isTerminal)
        XCTAssertTrue(FileV2SendState.sentAnnouncePending.isTerminal)
        XCTAssertTrue(FileV2SendState.failed(FileV2SendFailure(.network)).isTerminal)
        XCTAssertTrue(FileV2SendState.interrupted.isTerminal)
    }

    func testTheDefaultConfigurationIsTheProductionValues() {
        let configuration = FileV2SendConfiguration()
        XCTAssertEqual(configuration.directMaxUses, 30)
        XCTAssertNil(configuration.groupMaxUses)
        XCTAssertFalse(configuration.metered)
        XCTAssertEqual(configuration.maxAuthRefreshes, 2)
        XCTAssertEqual(configuration.orphanMinIdleMs, 600_000)
        XCTAssertEqual(configuration.retryPolicy.maxAttempts, 5)
        XCTAssertEqual(FileV2SendContext.perWorkerExtraBytes, 2 * Int64(FileV2.chunkSize), "the plaintext chunk and the sealed chunk")
    }

    func testTheSourceIdentityComparesSizeAndTimeAndNotTheLocator() {
        let base = FileV2SourceIdentity(locator: "/a/b", size: 10, modifiedMs: 5)
        XCTAssertTrue(base.isUnchanged(comparedTo: FileV2SourceIdentity(locator: "/elsewhere/after/an/app/update", size: 10, modifiedMs: 5)))
        XCTAssertFalse(base.isUnchanged(comparedTo: FileV2SourceIdentity(locator: "/a/b", size: 11, modifiedMs: 5)))
        XCTAssertFalse(base.isUnchanged(comparedTo: FileV2SourceIdentity(locator: "/a/b", size: 10, modifiedMs: 6)))
    }

    func testAFileSourceReadsItsIdentityAndExactRangesAndReportsAShortRead() throws {
        let directory = try FileV2TestSupport.makeTempDirectory(for: self)
        let url = directory.appendingPathComponent("data.bin")
        try Data((0..<1000).map { UInt8($0 % 251) }).write(to: url)
        let source = FileV2FileSource(url: url)
        let identity = try source.currentIdentity()
        XCTAssertEqual(identity.size, 1000)
        XCTAssertEqual(identity.locator, url.path)
        let reader = try source.makeReader()
        defer { reader.close() }
        XCTAssertEqual(try reader.read(offset: 10, length: 5), Data([10, 11, 12, 13, 14]))
        XCTAssertEqual(try reader.read(offset: 0, length: 0), Data())
        XCTAssertThrowsError(try reader.read(offset: 998, length: 5)) { XCTAssertEqual($0 as? FileV2SendSourceError, .shortRead) }
        reader.close()
        XCTAssertThrowsError(try reader.read(offset: 0, length: 1)) { XCTAssertEqual($0 as? FileV2SendSourceError, .unavailable) }
        XCTAssertEqual(SendStoreFixtures.printed(source).contains(directory.path), false, "a source never prints its path")

        XCTAssertThrowsError(try FileV2FileSource(url: directory.appendingPathComponent("missing")).currentIdentity())
        let provided = try FileV2FileSourceProvider().source(for: identity)
        XCTAssertEqual(try provided.currentIdentity(), identity)
    }

    func testTheSystemSleeperSleepsAndStopsWhenCancelled() async throws {
        let started = Date()
        try await FileV2SystemSleeper().sleep(milliseconds: 20)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.015)
        let sleeping = Task { try await FileV2SystemSleeper().sleep(milliseconds: 3_600_000) }
        sleeping.cancel()
        do {
            try await sleeping.value
            XCTFail("a cancelled sleep must throw")
        } catch is CancellationError {
        }
    }
}
