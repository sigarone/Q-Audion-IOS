import XCTest
@testable import QAudionEngine

/// The group-call diagnosis lines (2026-10-02). Every expected string here is pinned,
/// verbatim, in `scripts/test_ship_ios_redactor_hardening.py` too: the phone-log shipper
/// must keep each one unchanged. Change a format here and there together.
final class GroupDiagnosticsTests: XCTestCase {

    func testStateLines() {
        XCTAssertEqual(GroupDiagnostics.stateLine(.active(callId: "c", participants: ["a", "b", "c"]), old: .connecting(callId: "c")),
                       "grp state=2 old=1 count=3")
        XCTAssertEqual(GroupDiagnostics.stateLine(.idle, old: .active(callId: "c", participants: ["a", "b"])),
                       "grp state=0 old=2 count=0")
        XCTAssertEqual(GroupDiagnostics.stateLine(.failed(reason: "media_error"), old: .connecting(callId: "c")),
                       "grp state=3 old=1 count=0")
    }

    func testErrorLinesAreNumericCodes() {
        XCTAssertEqual(GroupDiagnostics.errorLine(.cameraPermissionDenied), "grp error code=1")
        XCTAssertEqual(GroupDiagnostics.errorLine(.cameraUnavailable), "grp error code=2")
        XCTAssertEqual(GroupDiagnostics.errorLine(.mediaLost), "grp error code=9")
        // The free-text payload of `.other` never reaches the line.
        XCTAssertEqual(GroupDiagnostics.errorLine(.other("anything at all")), "grp error code=10")
    }

    func testPromotionLines() {
        XCTAssertEqual(GroupDiagnostics.promotionLine(.begun, ms: 0), "grp swap phase=1 ms=0")
        XCTAssertEqual(GroupDiagnostics.promotionLine(.handedOver, ms: 3460), "grp swap phase=4 ms=3460")
        XCTAssertEqual(GroupDiagnostics.promotionLine(.routeSampled, ms: -5), "grp swap phase=5 ms=0")
    }

    func testVideoLines() {
        XCTAssertEqual(GroupDiagnostics.videoLine(camera: true, phase: .requested, ok: true),
                       "grp video camera=1 phase=1 ok=1 code=0 ms=0")
        XCTAssertEqual(GroupDiagnostics.videoLine(camera: true, phase: .camera, ok: false,
                                                  code: GroupDiagnostics.cameraCode(.noCamera), ms: 120),
                       "grp video camera=1 phase=2 ok=0 code=3 ms=120")
        XCTAssertEqual(GroupDiagnostics.videoLine(camera: true, phase: .firstFrame, ok: true, ms: 850),
                       "grp video camera=1 phase=5 ok=1 code=0 ms=850")
        XCTAssertEqual(GroupDiagnostics.videoLine(camera: false, phase: .configureAnswered, ok: true, ms: 40),
                       "grp video camera=0 phase=4 ok=1 code=0 ms=40")
        XCTAssertEqual(GroupDiagnostics.videoLine(camera: true, phase: .singleLayerFallback, ok: true, ms: 8_120),
                       "grp video camera=1 phase=7 ok=1 code=0 ms=8120")
    }

    func testHeartbeatLines() {
        XCTAssertEqual(GroupDiagnostics.iceLine(publisher: .connected, subscriber: .connected), "grp hb ice send=2 recv=2")
        XCTAssertEqual(GroupDiagnostics.iceLine(publisher: .connecting, subscriber: nil), "grp hb ice send=1 recv=9")
        XCTAssertEqual(GroupDiagnostics.rxAudioLine(mid: "0", index: 0, bytes: 40960, lost: 0, level: 0.12),
                       "grp hb audio mid=0 bytes=40960 lost=0 rxlvl=12")
        // A mid that is not a number falls back to its index; counters are clamped to
        // 0...9999999 (the shipper keeps at most 7 digits) and the level to 0...100.
        XCTAssertEqual(GroupDiagnostics.rxAudioLine(mid: "audio-x", index: 3, bytes: -10, lost: 20_000_000, level: 1.7),
                       "grp hb audio mid=3 bytes=0 lost=9999999 rxlvl=100")
        XCTAssertEqual(GroupDiagnostics.txLine(audioBytes: 40960, videoBytes: 1_200_000, framesEncoded: 150),
                       "grp hb tx audio=40960 video=1200000 frames=150")
    }

    func testRouteLines() {
        XCTAssertEqual(GroupDiagnostics.routeLine(portType: "Speaker", volume: 0.5625), "grp route out=2 vol=56")
        XCTAssertEqual(GroupDiagnostics.routeLine(portType: "Receiver", volume: 1.0), "grp route out=1 vol=100")
        XCTAssertEqual(GroupDiagnostics.routeLine(portType: "BluetoothHFP", volume: 0.25), "grp route out=3 vol=25")
        XCTAssertEqual(GroupDiagnostics.routeLine(portType: nil, volume: 0), "grp route out=0 vol=0")
        // A port type never seen before is "other", never its name.
        XCTAssertEqual(GroupDiagnostics.routeLine(portType: "SomethingNew", volume: 0.5), "grp route out=9 vol=50")
        // A volume the system cannot produce never traps the line.
        XCTAssertEqual(GroupDiagnostics.routeLine(portType: "Speaker", volume: .nan), "grp route out=2 vol=0")
    }

    /// One line per route change while a group call is live: the reason, the output the
    /// route left, the output it reached and the volume. The speaker -> earpiece ->
    /// speaker blip of the 1:1 -> group hand-over (report 93005f73, 07:13:50.29 and
    /// 07:13:50.345) is two lines.
    func testRouteChangeLines() {
        XCTAssertEqual(GroupDiagnostics.routeChangeLine(reason: 3, previousPortType: "Speaker", portType: "Receiver", volume: 1.0),
                       "grp route why=3 old=2 out=1 vol=100")
        XCTAssertEqual(GroupDiagnostics.routeChangeLine(reason: 3, previousPortType: "Receiver", portType: "Speaker", volume: 0.5),
                       "grp route why=3 old=1 out=2 vol=50")
        // The override that re-reports the same output (Speaker -> Speaker at 07:13:49.801).
        XCTAssertEqual(GroupDiagnostics.routeChangeLine(reason: 4, previousPortType: "Speaker", portType: "Speaker", volume: 0.5),
                       "grp route why=4 old=2 out=2 vol=50")
        // No route description / an unknown port: codes, never names; a reason is clamped.
        XCTAssertEqual(GroupDiagnostics.routeChangeLine(reason: 0, previousPortType: nil, portType: "SomethingNew", volume: 0.25),
                       "grp route why=0 old=0 out=9 vol=25")
        XCTAssertEqual(GroupDiagnostics.routeChangeLine(reason: 20_000_000, previousPortType: "BluetoothHFP", portType: "Receiver", volume: 2),
                       "grp route why=9999999 old=3 out=1 vol=100")
    }

    func testPcStateCodes() {
        XCTAssertEqual(GroupDiagnostics.pcStateCode(.new), 0)
        XCTAssertEqual(GroupDiagnostics.pcStateCode(.connected), 2)
        XCTAssertEqual(GroupDiagnostics.pcStateCode(.closed), 5)
        XCTAssertEqual(GroupDiagnostics.pcStateCode(nil), 9)
    }
}
