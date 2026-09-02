import XCTest
@testable import QAudionEngine

/// TRUST-2 (`docs/security/CRYPTO_PROTOCOL_AUDIT_2026-09-01.md`) — coverage
/// for the persisted `(device_id, nonce)` replay set. Shape mirrors
/// `KmsPreBootstrapReplayCache`'s own test coverage (TTL, LRU eviction,
/// `putIfAbsent` semantics); the property `KmsPreBootstrapReplayCache` does
/// NOT need and this one does — surviving a process restart inside the
/// freshness window — gets its own dedicated tests using a real temp-file
/// `persistenceURL` rather than `nil`.
final class WipeReplayCacheTests: XCTestCase {

    private var tempURL: URL!

    override func setUp() {
        super.setUp()
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wipe_replay_cache_test_\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempURL)
        tempURL = nil
        super.tearDown()
    }

    private func nonce(_ byte: UInt8) -> Data { Data(repeating: byte, count: 16) }

    // MARK: - Basic putIfAbsent semantics (in-memory, persistenceURL: nil)

    func testFirstSeenPairIsAccepted() {
        let cache = WipeReplayCache(persistenceURL: nil)
        XCTAssertTrue(cache.putIfAbsent(deviceId: "dev-1", nonce: nonce(0x01), nowMs: 1_000))
        XCTAssertEqual(cache.size(), 1)
    }

    func testSamePairSeenTwiceIsRejectedTheSecondTime() {
        let cache = WipeReplayCache(persistenceURL: nil)
        XCTAssertTrue(cache.putIfAbsent(deviceId: "dev-1", nonce: nonce(0x01), nowMs: 1_000))
        XCTAssertFalse(cache.putIfAbsent(deviceId: "dev-1", nonce: nonce(0x01), nowMs: 1_500))
    }

    func testSameNonceDifferentDeviceIsNotATreatedAsCollision() {
        let cache = WipeReplayCache(persistenceURL: nil)
        XCTAssertTrue(cache.putIfAbsent(deviceId: "dev-1", nonce: nonce(0x01), nowMs: 1_000))
        XCTAssertTrue(cache.putIfAbsent(deviceId: "dev-2", nonce: nonce(0x01), nowMs: 1_000))
    }

    func testEntryExpiresAfterTtlAndCanBeReusedSafely() {
        // Not a security regression: by the time the cache's own TTL has
        // elapsed, WipeCommandVerifier's independent `issued_at` freshness
        // check (5 min default) has ALREADY rejected the command on its own
        // — this only proves the cache doesn't grow unbounded, not that a
        // stale command becomes acceptable again in practice.
        let cache = WipeReplayCache(ttlMillis: 1_000, maxEntries: 256, persistenceURL: nil)
        XCTAssertTrue(cache.putIfAbsent(deviceId: "dev-1", nonce: nonce(0x01), nowMs: 0))
        XCTAssertFalse(cache.putIfAbsent(deviceId: "dev-1", nonce: nonce(0x01), nowMs: 500))
        XCTAssertTrue(cache.putIfAbsent(deviceId: "dev-1", nonce: nonce(0x01), nowMs: 2_000))
    }

    func testLruEvictsOldestWhenOverCapacity() {
        let cache = WipeReplayCache(ttlMillis: 60_000, maxEntries: 2, persistenceURL: nil)
        XCTAssertTrue(cache.putIfAbsent(deviceId: "dev-1", nonce: nonce(0x01), nowMs: 0))
        XCTAssertTrue(cache.putIfAbsent(deviceId: "dev-1", nonce: nonce(0x02), nowMs: 0))
        XCTAssertTrue(cache.putIfAbsent(deviceId: "dev-1", nonce: nonce(0x03), nowMs: 0))
        XCTAssertEqual(cache.size(), 2)
        // The oldest entry (0x01) was evicted — it is now "unseen" again.
        XCTAssertTrue(cache.putIfAbsent(deviceId: "dev-1", nonce: nonce(0x01), nowMs: 0))
    }

    func testClearEmptiesTheCache() {
        let cache = WipeReplayCache(persistenceURL: nil)
        _ = cache.putIfAbsent(deviceId: "dev-1", nonce: nonce(0x01), nowMs: 0)
        cache.clear()
        XCTAssertEqual(cache.size(), 0)
    }

    // MARK: - Persistence (TRUST-2's actual point: survive a relaunch)

    func testEntrySurvivesAFreshInstanceOverTheSamePersistenceFile() {
        let first = WipeReplayCache(persistenceURL: tempURL)
        XCTAssertTrue(first.putIfAbsent(deviceId: "dev-1", nonce: nonce(0x01), nowMs: 1_000))

        // Simulate a process relaunch: a BRAND NEW instance pointed at the
        // same file must already know about the entry.
        let second = WipeReplayCache(persistenceURL: tempURL)
        XCTAssertEqual(second.size(), 1)
        XCTAssertFalse(
            second.putIfAbsent(deviceId: "dev-1", nonce: nonce(0x01), nowMs: 1_500),
            "a nonce seen by a PRIOR process instance must still be rejected as a replay after relaunch"
        )
    }

    func testMissingPersistenceFileStartsEmptyRatherThanThrowing() {
        // tempURL was never written to — loadFromDiskLocked must degrade to
        // an empty cache, not crash or throw.
        let cache = WipeReplayCache(persistenceURL: tempURL)
        XCTAssertEqual(cache.size(), 0)
        XCTAssertTrue(cache.putIfAbsent(deviceId: "dev-1", nonce: nonce(0x01), nowMs: 0))
    }

    func testCorruptPersistenceFileDegradesToEmptyRatherThanCrashing() throws {
        try "not valid json at all {".write(to: tempURL, atomically: true, encoding: .utf8)
        let cache = WipeReplayCache(persistenceURL: tempURL)
        XCTAssertEqual(cache.size(), 0, "a corrupt persisted file must fail safe to empty, never crash the app")
        XCTAssertTrue(cache.putIfAbsent(deviceId: "dev-1", nonce: nonce(0x01), nowMs: 0))
    }

    func testDefaultProductionInitializerBuildsAWorkingCache() {
        // Exercises the public convenience init (Application Support-backed)
        // end to end — mainly a smoke test that
        // WipeReplayCache.defaultPersistenceURL() resolves and the instance
        // is usable; does not assert on the real on-disk file's location.
        let cache = WipeReplayCache()
        XCTAssertTrue(cache.putIfAbsent(deviceId: "smoke-test-dev", nonce: nonce(0xFF), nowMs: Int64(Date().timeIntervalSince1970 * 1000)))
        cache.clear()
    }
}
