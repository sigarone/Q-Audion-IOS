import XCTest
import CryptoKit
@testable import QAudionEngine

/// Replays the server conformance transcript (`file-v2-server-transcript.json`, a byte-for-byte copy of the server repository's
/// `test/kat/file_v2_server/transcript.json`, which that repository replays against its real handlers) against the in-memory
/// fake of the server, and holds the fake to the same numbers the library uses.
///
/// Nothing in this class skips: a missing or changed transcript fails, and every one of its 59 scenarios is replayed (the
/// fake models the concurrency, the timers, the server seams and the HTTP-level inputs of the transcript, see
/// `XferReplayCapabilities`). The list of scenarios that were not replayed is pinned, and it is empty.
final class FileV2ServerTranscriptTests: XCTestCase {

    private func transcript() throws -> XferTranscript { try XferTranscript.load() }

    /// One activity per scenario in the result bundle (XCTest on Linux has no activities).
    private func activity(_ name: String, _ body: () -> Void) {
        #if canImport(Darwin)
        XCTContext.runActivity(named: name) { _ in body() }
        #else
        body()
        #endif
    }

    // MARK: The file itself

    func testTranscriptIsAByteIdenticalCopyOfTheServerFile() throws {
        let bytes = try XferTranscript.bytes()
        XCTAssertEqual(bytes.count, XferTranscript.pinnedLength, "length of the transcript changed")
        XCTAssertEqual(XferSupport.sha256Hex(bytes), XferTranscript.pinnedSHA256,
                       "the transcript is not the pinned byte-for-byte copy of the server file")
        XCTAssertFalse(bytes.contains(0x0D), "a CR in the transcript: line endings were rewritten (.gitattributes -text)")
    }

    func testTranscriptShape() throws {
        let transcript = try self.transcript()
        XCTAssertEqual(transcript.version, 1)
        XCTAssertEqual(transcript.patternName, "fmix32")
        XCTAssertEqual(transcript.scenarios.count, 59)
        XCTAssertEqual(transcript.scenarios.reduce(0) { $0 + $1.steps.count }, 781)
        let names = transcript.scenarios.map { $0.name }
        XCTAssertEqual(Set(names).count, names.count, "two scenarios share a name")
    }

    // MARK: Constants

    /// The numbers the transcript depends on are the ones of the library and of the fake: a change of the part size or of a
    /// limit on the server changes the transcript, and this test then names the constant that moved.
    func testConstantsAreTheOnesOfTheLibraryAndTheFake() throws {
        let transcript = try self.transcript()
        let config = FakeCoreConfig()
        func constant(_ name: String) -> Int64 { transcript.constant(name) ?? -1 }
        XCTAssertEqual(constant("header_len"), Int64(FileV2.headerLength))
        XCTAssertEqual(constant("stride"), Int64(FileV2.stride))
        XCTAssertEqual(constant("part_size"), Int64(FileV2Wire.partSize))
        XCTAssertEqual(constant("max_parts"), Int64(FileV2Wire.maxParts))
        XCTAssertEqual(constant("max_blob"), Int64(FileV2.maxBlob))
        XCTAssertEqual(constant("default_quota"), config.quota)
        XCTAssertEqual(constant("default_max_incomplete_per_user"), Int64(config.maxIncompletePerUser))
        XCTAssertEqual(constant("default_max_objects_per_user"), Int64(config.maxObjectsPerUser))
        XCTAssertEqual(constant("default_max_unfinished_bytes"), config.maxUnfinishedBytes)
        XCTAssertEqual(constant("default_completed_retention_ms"), config.completedRetentionMs)
        XCTAssertEqual(constant("default_incomplete_retention_ms"), config.incompleteAbandonMs)
        XCTAssertEqual(constant("default_incomplete_max_lifetime_ms"), config.incompleteMaxLifetimeMs)
        XCTAssertEqual(constant("default_create_gate_wait_ms"), config.createGateWaitMs)
        XCTAssertEqual(constant("default_max_parts_in_flight_per_user"), Int64(config.maxPartsInFlightPerUser))
        XCTAssertEqual(constant("default_max_downloads_per_user"), Int64(config.maxDownloadsPerUser))
        XCTAssertEqual(constant("default_stream_wait_max_ms"), config.streamWaitMaxMs)
        XCTAssertEqual(constant("part_lock_wait_ms"), config.partLockWaitMs)
        XCTAssertEqual(constant("min_free_bytes"), config.minFreeBytes)
        XCTAssertEqual(constant("recommended_parallelism"), Int64(config.recommendedParallelism))
        XCTAssertEqual(constant("max_parallelism"), Int64(FileV2AdaptiveParallelism.hardCeiling))
        XCTAssertEqual(constant("default_token_ttl_seconds"), FakeFileV2Core.defaultTokenTTLSeconds)
        XCTAssertEqual(constant("max_token_ttl_seconds"), FakeFileV2Core.maxTokenTTLSeconds)
        XCTAssertEqual(constant("default_token_max_uses"), FakeFileV2Core.defaultTokenMaxUses)
        XCTAssertEqual(constant("max_token_max_uses"), FakeFileV2Core.maxTokenMaxUses)
        XCTAssertEqual(constant("max_groups_per_object"), Int64(FakeFileV2Core.maxGroupsPerObject))
        XCTAssertEqual(constant("byte_cap_multiplier"), 8)
        XCTAssertEqual(constant("list_default_limit"), Int64(FakeFileV2Core.listDefaultLimit))
        XCTAssertEqual(constant("list_max_limit"), Int64(FakeFileV2Core.listMaxLimit))
        XCTAssertEqual(constant("missing_parts_listed_by_complete"), 32)
        XCTAssertEqual(transcript.constants.member("path_prefix")?.stringValue, FileV2Wire.pathPrefix)

        // the Retry-After values of the table, which the typed errors carry
        let retry = transcript.constants.member("retry_after_seconds")
        XCTAssertEqual(retry?.member("part_busy")?.intValue, 2)
        XCTAssertEqual(retry?.member("create_busy")?.intValue, 2)
        XCTAssertEqual(retry?.member("too_many_parts_in_flight")?.intValue, 1)
        XCTAssertEqual(retry?.member("parts_not_yet_received")?.intValue, 1)
        XCTAssertEqual(retry?.member("too_many_downloads")?.intValue, 5)
        XCTAssertEqual(retry?.member("too_many_uploads")?.intValue, 30)
        XCTAssertEqual(retry?.member("insufficient_storage_server_cap")?.intValue, 60)

        // MAX_BLOB is exactly 640 full parts
        XCTAssertEqual(FileV2Wire.partCount(blobLength: Int64(FileV2.maxBlob)), FileV2Wire.maxParts)
        XCTAssertEqual(Int64(FileV2.maxBlob), Int64(FileV2.headerLength) + Int64(FileV2Wire.maxParts) * Int64(FileV2Wire.partSize))
    }

    // MARK: The byte pattern and the blobs

    func testPatternMatchesTheVectorsOfTheTranscript() throws {
        let transcript = try self.transcript()
        XCTAssertGreaterThanOrEqual(transcript.patternVectors.count, 10)
        for vector in transcript.patternVectors {
            XCTAssertEqual(XferPattern.byte(seed: vector.seed, index: vector.index), vector.byte,
                           "seed \(vector.seed) index \(vector.index)")
            XCTAssertEqual(XferPattern.bytes(seed: vector.seed, from: vector.index, count: 1), Data([vector.byte]))
        }
        // a slice is the same as the bytes one by one, including across 2^32 (the index wraps)
        let slice = XferPattern.bytes(seed: 42, from: 4_294_967_290, count: 12)
        for offset in 0..<12 {
            XCTAssertEqual(slice[slice.startIndex + offset], XferPattern.byte(seed: 42, index: 4_294_967_290 + Int64(offset)))
        }
    }

    /// Every blob of every scenario: the geometry, the 64-byte header the transcript publishes, and the SHA-256 of every part.
    /// This is what proves the byte generator (the 32-bit multiplies) before a replay depends on it.
    func testBlobsMatchTheirPublishedHeadersAndPartHashes() throws {
        let transcript = try self.transcript()
        var checked = 0
        for scenario in transcript.scenarios {
            for blob in scenario.blobs {
                XCTAssertEqual(blob.parts, FileV2Wire.partCount(blobLength: blob.length), "\(scenario.name) \(blob.name)")
                XCTAssertEqual(XferSupport.base64(blob.head), blob.headBase64, "\(scenario.name) \(blob.name) head")
                if blob.declaredOnly {
                    XCTAssertNil(blob.partsSHA256, "\(scenario.name) \(blob.name)")
                    XCTAssertGreaterThan(blob.length, 128 << 20, "\(scenario.name) \(blob.name): declared only below 128 MiB")
                    continue
                }
                guard let hashes = blob.partsSHA256 else {
                    XCTFail("\(scenario.name) \(blob.name): no part hashes")
                    continue
                }
                XCTAssertEqual(hashes.count, blob.parts)
                for index in 0..<blob.parts {
                    XCTAssertEqual(XferSupport.sha256Hex(blob.part(index)), hashes[index], "\(scenario.name) \(blob.name) part \(index)")
                    checked += 1
                }
            }
        }
        XCTAssertGreaterThan(checked, 100)
    }

    // MARK: The replay

    /// The scenarios that were not replayed, pinned: the fake honours every capability the transcript asks for.
    static let pinnedSkippedScenarios: [String] = []

    func testEveryScenarioIsReplayedAgainstTheFake() throws {
        let transcript = try self.transcript()
        var skipped = [String]()
        var failed = [String]()
        var steps = 0
        var checks = 0
        var listed = 0
        for scenario in transcript.scenarios {
            listed += FileV2ServerTranscriptTests.listedExpectations(in: scenario)
            activity(scenario.name) {
                let report = XferScenarioRun(transcript: transcript, scenario: scenario).run()
                steps += report.stepsRun
                checks += report.checksRun
                if let reason = report.skipped {
                    skipped.append(scenario.name)
                    XCTFail("\(scenario.name) skipped: \(reason)")
                }
                for failure in report.failures {
                    failed.append(failure)
                    XCTFail(failure)
                }
            }
        }
        XCTAssertEqual(skipped, FileV2ServerTranscriptTests.pinnedSkippedScenarios)
        XCTAssertEqual(steps, 781, "every step of every scenario runs")
        XCTAssertEqual(checks, listed, "every status, code, header, JSON path, body and wait the transcript lists is compared")
        XCTAssertGreaterThan(listed, 1000)
        XCTAssertTrue(failed.isEmpty, "\(failed.count) failures")
    }

    /// The number of items the transcript lists to compare, counted from the file itself (not from the runner).
    private static func listedExpectations(in scenario: XferScenario) -> Int {
        var count = 0
        for step in scenario.steps {
            guard let expect = step.expect else { continue }
            if expect.member("aborted")?.boolValue ?? false {
                count += 1
                continue
            }
            if expect.member("status") != nil { count += 1 }
            if expect.member("code") != nil { count += 1 }
            count += expect.member("headers")?.objectMembers?.count ?? 0
            count += expect.member("json")?.objectMembers?.count ?? 0
            if expect.member("body") != nil { count += 1 }
            if expect.member("waited_ms") != nil { count += 1 }
        }
        return count
    }

    // MARK: The replay is not vacuous

    /// A fake that differs from the real server on one number is caught by the replay: each mutation below changes one limit or
    /// one behaviour of the fake after the scenario's own configuration is applied, and at least one scenario must fail.
    func testTheReplayCatchesAFakeThatDriftsFromTheServer() throws {
        let transcript = try self.transcript()
        let mutations: [(String, (FakeFileV2Core) -> Void)] = [
            ("one more unfinished object per account", { $0.config.maxIncompletePerUser += 1 }),
            ("a shorter wait for a busy part", { $0.config.partLockWaitMs = 4_000 }),
            ("a longer cap on the stream wait", { $0.config.streamWaitMaxMs = 40_000 }),
            ("a smaller quota", { $0.config.quota -= 1 }),
            ("a shorter retention of an unfinished object", { $0.config.incompleteAbandonMs -= 1 }),
            ("a longer retention of a completed object", { $0.config.completedRetentionMs += 1 }),
            ("a different in-flight cap", { $0.config.maxPartsInFlightPerUser = 15 }),
            ("a different download cap", { $0.config.maxDownloadsPerUser = 11 }),
            ("a different recommended parallelism", { $0.config.recommendedParallelism = 5 }),
            ("a smaller server-wide cap", { $0.config.maxUnfinishedBytes /= 2 }),
            ("no group store", { $0.config.hasGroupStore = false }),
            ("no token secret", { $0.config.hasTokenSecret = false }),
            ("a disk that is always full", { $0.config.freeBytes = 0 }),
            ("a disk floor of nothing", { $0.config.minFreeBytes = -(1 << 40) }),
            ("a group store that always fails", { $0.groupLookupFails = true }),
            ("a create that is held at the gate", { $0.holdCreateGate = true })
        ]
        for (name, mutate) in mutations {
            var caught = false
            for scenario in transcript.scenarios {
                let run = XferScenarioRun(transcript: transcript, scenario: scenario)
                run.mutateConfigAfterSetup = mutate
                if !run.run().failures.isEmpty {
                    caught = true
                    break
                }
            }
            XCTAssertTrue(caught, "the replay did not notice: \(name)")
        }
    }
}
