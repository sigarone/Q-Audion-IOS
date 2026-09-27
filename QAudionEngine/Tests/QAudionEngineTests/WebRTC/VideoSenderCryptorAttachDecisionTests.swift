import XCTest
@testable import QAudionEngine

/// W-CRYPTORQUEUE (2026-09-27) — pins the three cases
/// `attachVideoSenderCryptorOnQueue` relies on: an already-attached sender
/// short-circuits regardless of `hasLocalVideoSender`, an audio-only call
/// (no local video sender) skips without attempting, and a video call whose
/// sender exists but is not yet attached attempts the attach.
final class VideoSenderCryptorAttachDecisionTests: XCTestCase {

    func test_alreadyAttached_winsRegardlessOfSenderPresence() {
        XCTAssertEqual(
            VideoSenderCryptorAttachDecision.evaluate(senderIsAttached: true, hasLocalVideoSender: false),
            .alreadyAttached)
        XCTAssertEqual(
            VideoSenderCryptorAttachDecision.evaluate(senderIsAttached: true, hasLocalVideoSender: true),
            .alreadyAttached)
    }

    /// The audio-only case this task's fix targets: no local video sender
    /// ever appears, so retrying must stop being attempted at all — not
    /// just fail loudly 5 times.
    func test_audioOnlyCall_skipsWithoutAttempting() {
        XCTAssertEqual(
            VideoSenderCryptorAttachDecision.evaluate(senderIsAttached: false, hasLocalVideoSender: false),
            .skipNoSender)
    }

    func test_videoCallWithUnattachedSender_attempts() {
        XCTAssertEqual(
            VideoSenderCryptorAttachDecision.evaluate(senderIsAttached: false, hasLocalVideoSender: true),
            .attempt)
    }
}
