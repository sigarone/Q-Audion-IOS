import XCTest
@testable import QAudionEngine

/// R-READY (WIRE_SPEC §8.7): a first-video ready must be distinguishable from a rekey ready. The
/// first-video ready of a call that upgraded to video in round R carries `key_epoch = R - 1 > 0`,
/// so `key_epoch > 0` alone must never be read as the rekey ready the sender-switch gate waits on.
final class MediaReadyRoutingTests: XCTestCase {

    private let videoMid = "1"

    private func route(
        media: String, mid: String, epoch: Int, armedAudio: Int32 = -1, armedVideo: Int32 = -1
    ) -> MediaReadyRouting.Route {
        MediaReadyRouting.route(
            media: media, mid: mid, keyEpoch: epoch,
            armedEpoch: { $0 == "audio" ? armedAudio : armedVideo })
    }

    /// The bug: a first-video ready with E = 2 landed while the video gate was armed for E = 2.
    /// It was taken as the rekey ready, so the TX-hold release and the forced IDR were skipped.
    func testFirstVideoReadyWithTheArmedEpochIsNotARekeyReady() {
        XCTAssertEqual(route(media: "video", mid: videoMid, epoch: 2, armedVideo: 2), .firstVideoReady)
    }

    func testARekeyReadyCarriesNoMidAndMatchesTheArmedEpoch() {
        XCTAssertEqual(route(media: "video", mid: "", epoch: 2, armedVideo: 2), .rekeyReady(media: "video", epoch: 2))
        XCTAssertEqual(route(media: "audio", mid: "", epoch: 3, armedAudio: 3), .rekeyReady(media: "audio", epoch: 3))
    }

    func testARekeyReadyForAnotherEpochOrAnUnarmedGateIsNotTheRekeyBeingWaitedOn() {
        // Epoch differs from the armed one.
        XCTAssertEqual(route(media: "video", mid: "", epoch: 3, armedVideo: 2), .firstVideoReady)
        // Gate not armed.
        XCTAssertEqual(route(media: "video", mid: "", epoch: 2), .firstVideoReady)
    }

    func testTheGateOfTheOtherMediaKindDoesNotMatch() {
        // Video gate armed for 2: an AUDIO ready for epoch 2 must not switch the video sender.
        XCTAssertEqual(route(media: "audio", mid: "", epoch: 2, armedAudio: -1, armedVideo: 2), .ignore)
        XCTAssertEqual(route(media: "video", mid: "", epoch: 2, armedAudio: 2, armedVideo: -1), .firstVideoReady)
    }

    func testEpochZeroIsTheFirstVideoReady() {
        XCTAssertEqual(route(media: "video", mid: videoMid, epoch: 0), .firstVideoReady)
        XCTAssertEqual(route(media: "video", mid: "", epoch: 0, armedVideo: 0), .firstVideoReady)
    }

    /// An audio ready never has first-video meaning: no TX-hold release, no forced IDR.
    func testAnAudioReadyThatIsNotTheArmedRekeyIsIgnored() {
        XCTAssertEqual(route(media: "audio", mid: "", epoch: 0), .ignore)
        XCTAssertEqual(route(media: "audio", mid: "", epoch: 4, armedAudio: 3), .ignore)
    }

    /// A peer that predates the `media` field means video.
    func testUnknownMediaCountsAsVideo() {
        XCTAssertEqual(route(media: "", mid: "", epoch: 5, armedVideo: 5), .rekeyReady(media: "video", epoch: 5))
        XCTAssertEqual(route(media: "", mid: videoMid, epoch: 5, armedVideo: 5), .firstVideoReady)
    }

    func testAnEpochOutsideInt32IsNeverARekeyReady() {
        XCTAssertEqual(
            route(media: "video", mid: "", epoch: Int(Int32.max) + 1, armedVideo: Int32.max), .firstVideoReady)
    }

    // AppState cannot be driven here (CallKit, live provider, WebSocket): its handler is pinned on
    // the source text, like the other wiring invariants.
    func testTheAppRoutesCallMediaReadyThroughTheRouting() throws {
        var dir = URL(fileURLWithPath: #filePath)
        var text: String?
        for _ in 0..<10 {
            dir = dir.deletingLastPathComponent()
            let candidate = dir.appendingPathComponent("QAudionApp/AppState.swift")
            if FileManager.default.fileExists(atPath: candidate.path) {
                text = try String(contentsOf: candidate, encoding: .utf8)
                break
            }
        }
        guard let app = text else { throw XCTSkip("QAudionApp/AppState.swift not found") }
        XCTAssertTrue(app.contains("MediaReadyRouting.route("), "onCallMediaReady must classify through MediaReadyRouting")
        XCTAssertFalse(
            app.contains("ws.onCallMediaReady = { [weak self] callId, senderId, _, keyEpoch, _, media in"),
            "the handler must read the mid: key_epoch > 0 alone is not a rekey ready")
    }
}
