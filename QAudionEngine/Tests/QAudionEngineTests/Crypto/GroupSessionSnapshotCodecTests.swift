import XCTest
@testable import QAudionEngine

final class GroupSessionSnapshotCodecTests: XCTestCase {

    func testRoundTripEmptyRecv() throws {
        let session = GroupSession(vault: nil)
        let state = try session.create(
            groupIdBytes: Data([0xDE, 0xAD]),
            members: ["a", "b", "c"],
            admins: ["a"],
            selfId: "a",
            selfSeed: Data(repeating: 0x77, count: 32)
        )
        let blob = GroupSessionSnapshotCodec.encode(state)
        let back = try GroupSessionSnapshotCodec.decode(blob)
        XCTAssertEqual(back.groupIdBytes, state.groupIdBytes)
        XCTAssertEqual(back.groupEpoch, state.groupEpoch)
        XCTAssertEqual(back.members, state.members)
        XCTAssertEqual(back.admins, state.admins)
        XCTAssertEqual(back.selfId, state.selfId)
        XCTAssertEqual(back.sendChain.ck, state.sendChain.ck)
        XCTAssertEqual(back.sendChain.nextIdx, state.sendChain.nextIdx)
        XCTAssertNil(back.sendChain.lastSeenIdx)
        XCTAssertTrue(back.recvChains.isEmpty)
    }

    func testRoundTripWithRecvChainsAndSkipped() throws {
        let session = GroupSession(vault: nil)
        let state = try session.create(
            groupIdBytes: Data([0xDE, 0xAD, 0xBE, 0xEF]),
            members: ["a", "b"],
            admins: ["a"],
            selfId: "a",
            selfSeed: Data(repeating: 0xAA, count: 32)
        )
        // Inject a recv chain with a skipped key entry.
        let recv = GroupSenderChain.newRecv(
            ck: Data(repeating: 0x10, count: 32), lastSeenIdx: 4)
        recv.skipped.append((5, GroupSkippedKey(
            key: Data(repeating: 0x11, count: 32),
            nonce: Data(repeating: 0x12, count: 12),
            expiresAtMs: 1_700_000_000_000
        )))
        state.setRecvChain("b", recv)

        let blob = GroupSessionSnapshotCodec.encode(state)
        let back = try GroupSessionSnapshotCodec.decode(blob)
        XCTAssertEqual(back.recvChains.count, 1)
        XCTAssertEqual(back.recvChains[0].0, "b")
        XCTAssertEqual(back.recvChains[0].1.lastSeenIdx, 4)
        XCTAssertEqual(back.recvChains[0].1.skipped.count, 1)
        XCTAssertEqual(back.recvChains[0].1.skipped[0].0, 5)
        XCTAssertEqual(back.recvChains[0].1.skipped[0].1.key.count, 32)
    }

    func testRejectsWrongVersion() {
        let bad = Data([0x99] + [UInt8](repeating: 0, count: 100))
        XCTAssertThrowsError(try GroupSessionSnapshotCodec.decode(bad))
    }
}
