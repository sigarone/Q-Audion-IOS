import XCTest
@testable import QAudionEngine

/// The protection level, its summary line, and the DTLS group read from the native handshake report line. The shared
/// known-answer vectors of the level and of the line are run in PqcHardeningV1KatTests.
final class PqLevelTests: XCTestCase {

    func testLevelsAreOrderedWeakestFirst() {
        XCTAssertTrue(PqLevel.cl < .pq1)
        XCTAssertTrue(PqLevel.pq1 < .pq2s)
        XCTAssertTrue(PqLevel.pq2s < .pq2)
        XCTAssertEqual(PqLevel(token: "PQ2S"), .pq2s)
        XCTAssertNil(PqLevel(token: "pq2"))
    }

    func testTheCallLevelIsTheWeakestUsedPath() {
        let strong = PqLevelCalc.rtp(dtlsPq: true)                                   // PQ2
        let sameSecret = PqLevelCalc.relay(innerPq: true, outer: .same)              // PQ2S
        let single = PqLevelCalc.dcmux(dtlsPq: false, innerPq: true, outer: .off)    // PQ1
        XCTAssertEqual(PqLevelCalc.callLevel(paths: [strong]), .pq2)
        XCTAssertEqual(PqLevelCalc.callLevel(paths: [strong, sameSecret]), .pq2s)
        XCTAssertEqual(PqLevelCalc.callLevel(paths: [strong, sameSecret, single]), .pq1)
        XCTAssertNil(PqLevelCalc.callLevel(paths: []))
    }

    func testTheLegacySealOnBothLegsOfAHybridDtlsCallIsDouble() {
        XCTAssertEqual(PqLevelCalc.pathLevel(PqLevelCalc.dcmux(dtlsPq: true, innerPq: true, outer: .same)), .pq2)
        XCTAssertEqual(PqLevelCalc.pathLevel(PqLevelCalc.dcmux(dtlsPq: false, innerPq: true, outer: .same)), .pq2s)
        XCTAssertEqual(PqLevelCalc.pathLevel(PqLevelCalc.relay(innerPq: true, outer: .same)), .pq2s)
        XCTAssertEqual(PqLevelCalc.pathLevel(PqLevelCalc.relay(innerPq: true, outer: .off)), .pq1)
    }

    func testTheLineIsOneLineOfSingleSpacedTokensAndAnEmptyValuePrintsAsADash() {
        var line = PqLevelLine()
        line.call = "0a1b2c3d"
        line.level = "PQ2S"
        line.dtls = "cl"
        line.relay = "same"
        line.dcmux = "same"
        line.inner = "legacy"
        line.outer = "sealed"
        let text = line.format()
        XCTAssertEqual(text, "QA-PQLEVEL v=1 call=0a1b2c3d kind=1to1 level=PQ2S auth=C sas=0 dtls=cl frame=- relay=same "
            + "dcmux=same inner=legacy rvideo=- pin=- hold=0 withdraw=- caps=- pqstate=- pq_sig=- outer=sealed "
            + "reason=- rekey=- round=-")
        XCTAssertFalse(text.contains("  "))
        XCTAssertFalse(text.contains("\n"))
        // The group fields follow only a group line.
        XCTAssertFalse(text.contains(" tl="))
        line.kind = "group"
        line.tl = "pq"
        line.kd = "pq"
        line.unk = "0"
        XCTAssertTrue(line.format().hasSuffix(" tl=pq kd=pq unk=0"))
    }

    func testTheDtlsGroupIsReadFromTheHandshakeReportLine() {
        let hybrid = "Q-AUDION dtls v=0304 cipher=1302 srtp=0008 group=11ec level=3 pqc_req=1 ok=1"
        let classical = "Q-AUDION dtls v=0304 cipher=1302 srtp=0008 group=001d level=3 pqc_req=0 ok=1"
        XCTAssertEqual(PqDtlsGroup.token(fromHandshakeLine: hybrid), "pq")
        XCTAssertEqual(PqDtlsGroup.token(fromHandshakeLine: classical), "cl")
        XCTAssertNil(PqDtlsGroup.token(fromHandshakeLine: "Q-AUDION build=1"))
        XCTAssertNil(PqDtlsGroup.token(fromHandshakeLine: "Q-AUDION dtls group= level=3"))
        XCTAssertNil(PqDtlsGroup.token(fromHandshakeLine: "Q-AUDION dtls group=zzzz"))
    }
}
