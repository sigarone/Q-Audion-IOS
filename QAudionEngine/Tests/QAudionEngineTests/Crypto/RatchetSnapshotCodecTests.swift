import XCTest
@testable import QAudionEngine

final class RatchetSnapshotCodecTests: XCTestCase {

    func testEncodeDecodeRoundTrip() throws {
        let snap = RatchetSnapshot(
            epochId: "epoch-A",
            selfId: "alice",
            peerId: "bob",
            sendDirFlag: 0x01,
            recvDirFlag: 0x02,
            ckSend: Data(repeating: 0x11, count: 32),
            nextSendIdx: 7,
            ckRecv: Data(repeating: 0x22, count: 32),
            lastSeenRecvIdx: 4,
            skipped: [
                RatchetSnapshot.SkippedEntry(
                    idx: 5,
                    key: Data(repeating: 0x33, count: 32),
                    nonce: Data(repeating: 0x44, count: 12),
                    expiresAtMs: 1_700_000_000_000),
            ]
        )
        let blob = RatchetSnapshotCodec.encode(snap)
        let back = try RatchetSnapshotCodec.decode(blob)
        XCTAssertEqual(back, snap)
    }

    func testNilLastSeenRoundTrip() throws {
        let snap = RatchetSnapshot(
            epochId: "e",
            selfId: "a",
            peerId: "b",
            sendDirFlag: 0x01,
            recvDirFlag: 0x02,
            ckSend: Data(repeating: 0x01, count: 32),
            nextSendIdx: 0,
            ckRecv: Data(repeating: 0x02, count: 32),
            lastSeenRecvIdx: nil,
            skipped: []
        )
        let blob = RatchetSnapshotCodec.encode(snap)
        let back = try RatchetSnapshotCodec.decode(blob)
        XCTAssertNil(back.lastSeenRecvIdx)
    }

    func testRejectsWrongVersion() {
        var bad = Data([0x99]) // version != 0x01
        bad.append(contentsOf: [UInt8](repeating: 0, count: 100))
        XCTAssertThrowsError(try RatchetSnapshotCodec.decode(bad)) { err in
            guard case RatchetSnapshotCodec.CodecError.versionMismatch(let v) = err else {
                XCTFail("expected versionMismatch, got \(err)"); return
            }
            XCTAssertEqual(v, 0x99)
        }
    }

    func testRejectsTruncated() {
        XCTAssertThrowsError(try RatchetSnapshotCodec.decode(Data([0x01, 0x00, 0x00, 0x00])))
    }
}
