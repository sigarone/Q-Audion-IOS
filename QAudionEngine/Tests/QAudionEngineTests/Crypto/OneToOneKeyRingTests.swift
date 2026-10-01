import XCTest
@testable import QAudionEngine

/// R-RING (WIRE_SPEC §3.7.2): a 1:1 receiver keeps exactly {current, previously installed} key
/// rounds live and overwrites every other slot with RANDOM bytes (never zeros) when a new round is
/// installed. The previous round is the previously INSTALLED slot, not `E - 1`: rounds can have gaps.
final class OneToOneKeyRingTests: XCTestCase {

    func testFirstInstallRetiresNothing() {
        var ring = OneToOneKeyRingTracker()
        XCTAssertEqual(ring.install(slot: 0), [])
        XCTAssertEqual(ring.current, 0)
        XCTAssertNil(ring.previous)
    }

    func testSecondInstallKeepsBothRoundsLive() {
        var ring = OneToOneKeyRingTracker()
        _ = ring.install(slot: 0)
        XCTAssertEqual(ring.install(slot: 1), [], "{0, 1} are the two live rounds")
        XCTAssertEqual(ring.previous, 0)
    }

    func testThirdInstallRetiresTheOldestRound() {
        var ring = OneToOneKeyRingTracker()
        _ = ring.install(slot: 0)
        _ = ring.install(slot: 1)
        XCTAssertEqual(ring.install(slot: 2), [0], "only {1, 2} stay live; slot 0 is retired")
        XCTAssertEqual(ring.install(slot: 3), [1])
        XCTAssertEqual(ring.holdingRealKey, [2, 3])
    }

    /// Rounds can have gaps (a round that did not complete): the previous live round is the
    /// previously INSTALLED slot (0), not `E - 1` (slot 1 was never installed). Computing `E - 1`
    /// would randomise the live slot 0 and leave nothing retired.
    func testGapKeepsThePreviouslyInstalledSlotNotEMinusOne() {
        var ring = OneToOneKeyRingTracker()
        _ = ring.install(slot: 0)
        XCTAssertEqual(ring.install(slot: 2), [], "round 2 skipped: {0, 2} are live, nothing to retire")
        XCTAssertEqual(ring.previous, 0)
        XCTAssertEqual(ring.install(slot: 3), [0], "now {2, 3}: slot 0 is retired")
        XCTAssertEqual(ring.holdingRealKey, [2, 3])
    }

    func testReinstallingTheCurrentRoundIsIdempotent() {
        var ring = OneToOneKeyRingTracker()
        _ = ring.install(slot: 4)
        _ = ring.install(slot: 5)
        XCTAssertEqual(ring.install(slot: 5), [], "a re-publish of the live round changes nothing")
        XCTAssertEqual(ring.previous, 4, "and must not push the previous round out")
        XCTAssertEqual(ring.holdingRealKey, [4, 5])
    }

    /// Slots wrap at 16: epoch 16 lands on slot 0 again.
    func testWrapAroundRetiresTheRightSlots() {
        var ring = OneToOneKeyRingTracker()
        for slot in Int32(0)...15 { _ = ring.install(slot: slot) }
        XCTAssertEqual(ring.holdingRealKey, [14, 15])
        XCTAssertEqual(ring.install(slot: 0), [14])
        XCTAssertEqual(ring.holdingRealKey, [15, 0])
    }

    /// The slot this device's own sender still announces seals its outbound frames: it is not
    /// retired from under the sender, only by a later install once the sender has moved on.
    func testTheSlotOfTheOwnSenderIsNotRetiredYet() {
        var ring = OneToOneKeyRingTracker()
        _ = ring.install(slot: 0)
        _ = ring.install(slot: 1)
        XCTAssertEqual(ring.install(slot: 2, senderSlot: 0), [], "the sender is still on slot 0")
        XCTAssertEqual(ring.holdingRealKey, [0, 1, 2])
        XCTAssertEqual(ring.install(slot: 3, senderSlot: 2), [0, 1], "the sender moved on: both are retired")
        XCTAssertEqual(ring.holdingRealKey, [2, 3])
    }

    func testRetiredKeysAreRandomNeverZeroAndDistinct() {
        let a = OneToOneKeyRingTracker.randomRetiredKey()
        let b = OneToOneKeyRingTracker.randomRetiredKey()
        XCTAssertEqual(a.count, 32)
        XCTAssertEqual(b.count, 32)
        XCTAssertTrue(a.contains(where: { $0 != 0 }), "an all-zero key is a valid key for the native cryptor")
        XCTAssertTrue(b.contains(where: { $0 != 0 }))
        XCTAssertNotEqual(a, b, "each retired slot gets its own random bytes")
    }

    // The cryptors wrap native WebRTC objects that only exist in the WebRTC binary, so the wiring
    // is pinned on the source text (same choice as FrameCryptorProviderLifetimeTests).
    private func engineSource(_ relative: String) throws -> String {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { url.deleteLastPathComponent() }
        let file = url.appendingPathComponent("Sources/QAudionEngine").appendingPathComponent(relative)
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw XCTSkip("package sources are not on disk next to the tests")
        }
        return try String(contentsOf: file, encoding: .utf8)
    }

    func testBothCryptorsRetireThroughTheTrackerWithRandomBytes() throws {
        for file in ["WebRTC/NativeAudioFrameCryptor.swift", "WebRTC/NativeVideoFrameCryptor.swift"] {
            let text = try engineSource(file)
            XCTAssertTrue(text.contains("ringTracker.install(slot: slot"), "\(file): installKeys must retire through the tracker")
            XCTAssertEqual(text.components(separatedBy: "OneToOneKeyRingTracker.randomRetiredKey()").count - 1, 2,
                           "\(file): the local and the remote participant slot are both overwritten with random bytes")
            XCTAssertFalse(text.contains("Data(count: 32)"), "\(file): a retired slot must never be zeroed")
            XCTAssertFalse(text.contains("Data(repeating: 0"), "\(file): a retired slot must never be zeroed")
        }
    }
}
