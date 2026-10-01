import XCTest
@testable import QAudionEngine

/// R-RING (WIRE_SPEC §3.7.2): a 1:1 receiver keeps exactly {current, previously installed} key
/// rounds live and overwrites every other slot with RANDOM bytes (never zeros) when a new round is
/// installed. The previous round is the previously INSTALLED slot, not `E - 1`: rounds can have gaps.
final class OneToOneKeyRingTests: XCTestCase {

    private typealias Ring = OneToOneKeyRingTracker

    private func ret(_ remote: [Int32], _ local: [Int32]? = nil) -> Ring.Retirement {
        Ring.Retirement(remote: remote, local: local ?? remote)
    }

    func testFirstInstallRetiresNothing() {
        var ring = Ring()
        XCTAssertEqual(ring.install(slot: 0), .none)
        XCTAssertEqual(ring.current, 0)
        XCTAssertNil(ring.previous)
    }

    func testSecondInstallKeepsBothRoundsLive() {
        var ring = Ring()
        _ = ring.install(slot: 0)
        XCTAssertEqual(ring.install(slot: 1), .none, "{0, 1} are the two live rounds")
        XCTAssertEqual(ring.previous, 0)
    }

    func testThirdInstallRetiresTheOldestRound() {
        var ring = Ring()
        _ = ring.install(slot: 0)
        _ = ring.install(slot: 1)
        XCTAssertEqual(ring.install(slot: 2), ret([0]), "only {1, 2} stay live; slot 0 is retired")
        XCTAssertEqual(ring.install(slot: 3), ret([1]))
        XCTAssertEqual(ring.holdingRemoteKey, [2, 3])
        XCTAssertEqual(ring.holdingLocalKey, [2, 3])
    }

    /// Rounds can have gaps (a round that did not complete): the previous live round is the
    /// previously INSTALLED slot (0), not `E - 1` (slot 1 was never installed). Computing `E - 1`
    /// would randomise the live slot 0 and leave nothing retired.
    func testGapKeepsThePreviouslyInstalledSlotNotEMinusOne() {
        var ring = Ring()
        _ = ring.install(slot: 0)
        XCTAssertEqual(ring.install(slot: 2), .none, "round 2 skipped: {0, 2} are live, nothing to retire")
        XCTAssertEqual(ring.previous, 0)
        XCTAssertEqual(ring.install(slot: 3), ret([0]), "now {2, 3}: slot 0 is retired")
        XCTAssertEqual(ring.holdingRemoteKey, [2, 3])
    }

    func testReinstallingTheCurrentRoundIsIdempotent() {
        var ring = Ring()
        _ = ring.install(slot: 4)
        _ = ring.install(slot: 5)
        XCTAssertEqual(ring.install(slot: 5), .none, "a re-publish of the live round changes nothing")
        XCTAssertEqual(ring.previous, 4, "and must not push the previous round out")
        XCTAssertEqual(ring.holdingRemoteKey, [4, 5])
    }

    /// Slots wrap at 16: epoch 16 lands on slot 0 again.
    func testWrapAroundRetiresTheRightSlots() {
        var ring = Ring()
        for slot in Int32(0)...15 { _ = ring.install(slot: slot) }
        XCTAssertEqual(ring.holdingRemoteKey, [14, 15])
        XCTAssertEqual(ring.install(slot: 0), ret([14]))
        XCTAssertEqual(ring.holdingRemoteKey, [15, 0])
    }

    /// The RECEIVE side is strict: even the slot this device's own sender still announces loses its
    /// receive key at once. Only its own-direction (sealing) key is kept, until the sender moved on.
    func testTheReceiveKeyOfTheOwnSenderSlotIsRetiredButItsSealingKeyIsKept() {
        var ring = Ring()
        _ = ring.install(slot: 0)
        _ = ring.install(slot: 1)
        let third = ring.install(slot: 2, senderSlot: 0)
        XCTAssertEqual(third.remote, [0], "exactly {1, 2} stay live for receiving, whatever the sender does")
        XCTAssertEqual(third.local, [], "the sender is still sealing under slot 0")
        XCTAssertEqual(ring.holdingRemoteKey, [1, 2])
        XCTAssertEqual(ring.holdingLocalKey, [0, 1, 2])
        let fourth = ring.install(slot: 3, senderSlot: 2)
        XCTAssertEqual(fourth.remote, [1])
        XCTAssertEqual(fourth.local, [0, 1], "the sender moved on: its old sealing keys are retired")
        XCTAssertEqual(ring.holdingRemoteKey, [2, 3])
        XCTAssertEqual(ring.holdingLocalKey, [2, 3])
    }

    /// After any sequence of installs no more than two receive slots ever hold a real key.
    func testNeverMoreThanTwoReceiveSlotsAreLive() {
        var ring = Ring()
        var sender: Int32 = 0
        for slot: Int32 in [0, 1, 3, 4, 7, 8, 9, 15, 0, 1] {
            _ = ring.install(slot: slot, senderSlot: sender)
            sender = slot
            XCTAssertLessThanOrEqual(ring.holdingRemoteKey.count, 2)
            XCTAssertTrue(ring.holdingRemoteKey.contains(slot))
        }
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
                           "\(file): the receive and the own-direction slot are both overwritten with random bytes")
            XCTAssertTrue(text.contains("for old in retired.remote"), "\(file): the receive key of every retired slot is overwritten")
            XCTAssertTrue(text.contains("for old in retired.local"), "\(file): the sealing key of a retired slot is overwritten once the sender moved on")
            XCTAssertFalse(text.contains("Data(count: 32)"),"\(file): a retired slot must never be zeroed")
            XCTAssertFalse(text.contains("Data(repeating: 0"), "\(file): a retired slot must never be zeroed")
        }
    }
}
