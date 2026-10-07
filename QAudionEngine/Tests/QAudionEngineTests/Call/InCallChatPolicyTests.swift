import XCTest
@testable import QAudionEngine

/// The chat opened over a 1:1 call, on the audio call screen (PR 207) and now also on the video call screen.
///
/// `InCallChatPolicy` is the pure part: who the chat is with and when "take a photo" is refused. The UI cannot be driven in CI, so the
/// second half of this file pins the WIRING as source invariants, the same choice `CallerBusyWiringTests` makes: one owner of the cover
/// above both call screens, the Chat button on the video controls, the camera refusal on the one place that opens the camera, and
/// nothing of the call machinery (video pipeline, capture session, audio session, hangup, mute) in the chat host. Comments are
/// stripped and whitespace collapsed before matching, so only code counts. They do not prove the screen looks or behaves right on a
/// device; they fail when someone removes or re-routes the pieces.
final class InCallChatPolicyTests: XCTestCase {

    // MARK: - pure policy

    func testChatIsWithTheCallContact() {
        XCTAssertEqual(InCallChatPolicy.chatPeer(callContactId: "user-peer-1111"), "user-peer-1111")
    }

    /// No contact on the call (between calls, a screen of the design showcase): no button, and opening does nothing.
    func testNoPeerMeansNoChat() {
        XCTAssertNil(InCallChatPolicy.chatPeer(callContactId: nil))
        XCTAssertNil(InCallChatPolicy.chatPeer(callContactId: ""))
    }

    /// A video call owns the camera: the chat must not open a second capture session.
    func testCameraIsRefusedInAVideoCall() {
        XCTAssertTrue(InCallChatPolicy.cameraCaptureBlocked(inCall: true, videoCall: true))
    }

    /// An audio call does not use the camera: a photo from the chat is fine.
    func testCameraIsFreeInAnAudioCall() {
        XCTAssertFalse(InCallChatPolicy.cameraCaptureBlocked(inCall: true, videoCall: false))
    }

    /// The video flag can outlive a call; an ordinary chat (no call up) must never be refused the camera because of it.
    func testCameraIsFreeOutsideACall() {
        XCTAssertFalse(InCallChatPolicy.cameraCaptureBlocked(inCall: false, videoCall: true))
        XCTAssertFalse(InCallChatPolicy.cameraCaptureBlocked(inCall: false, videoCall: false))
    }

    // MARK: - reading the source

    /// The source file was not found: the test FAILS (it never skips).
    private struct SourceNotFound: Error, CustomStringConvertible {
        let path: String
        var description: String { "source file not found: \(path)" }
    }

    /// `relativePath` (from the repository root), line comments stripped and every run of whitespace collapsed to one space.
    private func code(
        _ relativePath: String, file: StaticString = #filePath, line: UInt = #line
    ) throws -> String {
        var dir = URL(fileURLWithPath: "\(file)")
        for _ in 0..<10 {
            dir = dir.deletingLastPathComponent()
            let candidate = dir.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                let raw = try String(contentsOf: candidate, encoding: .utf8)
                let withoutComments = raw
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .map { line -> Substring in
                        if let r = line.range(of: "//") { return line[line.startIndex..<r.lowerBound] }
                        return line
                    }
                    .joined(separator: "\n")
                return withoutComments.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            }
        }
        XCTFail("\(relativePath) not found from \(file): the wiring invariants cannot run", file: file, line: line)
        throw SourceNotFound(path: relativePath)
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    // MARK: - wiring

    /// One owner of the cover, above both call screens: `ContentView` wraps the in-call stack, and neither screen presents a cover of
    /// its own (a cover owned by one screen is torn down when `ContentView` swaps to the other).
    func testTheCoverHasOneOwnerAboveBothCallScreens() throws {
        let content = try code("QAudionApp/Views/ContentView.swift")
        XCTAssertTrue(
            content.contains("if appState.isInCall { InCallChatHost { inCallStack } }"),
            "ContentView must wrap the in-call stack in InCallChatHost for the life of the call")

        let video = try code("QAudionApp/Views/VideoCallView.swift")
        let live = try code("QAudionApp/Views/Call/LiveInCallScreen.swift")
        for (name, source) in [("VideoCallView", video), ("LiveInCallScreen", live)] {
            XCTAssertFalse(source.contains("InCallChatCover("), "\(name) must not present the chat cover itself")
            XCTAssertFalse(source.contains(".fullScreenCover("), "\(name) must not own a cover: the host above it does")
            XCTAssertTrue(source.contains("@Environment(\\.inCallChat)"), "\(name) gets the chat from the host")
        }
    }

    /// The host presents the cover with the ordinary chat, and re-locks the secure window when it closes.
    func testTheHostPresentsTheChatAndRestoresTheSecureWindow() throws {
        let host = try code("QAudionApp/Views/Call/InCallChatCover.swift")
        XCTAssertEqual(occurrences(of: ".fullScreenCover(item: $chat.target", in: host), 1)
        XCTAssertTrue(host.contains("onDismiss: { ScreenshotLockService.lock()"))
        XCTAssertTrue(host.contains("InCallChatCover(target: target)"))
        XCTAssertTrue(host.contains("ChatDetailScreen( conversationId: target.conversationId"))
    }

    /// The Chat button is part of the video call controls, before the hangup, and shows the unread dot.
    func testTheVideoControlsOfferTheChat() throws {
        let video = try code("QAudionApp/Views/VideoCallView.swift")
        XCTAssertTrue(video.contains("if let chat = inCallChat { chatButton(chat) }"))
        XCTAssertTrue(video.contains("badge: chat.hasUnread"))
        let chatPos = try XCTUnwrap(video.range(of: "chatButton(chat) }"))
        let hangupPos = try XCTUnwrap(video.range(of: "label: \"Termina\""))
        XCTAssertLessThan(chatPos.lowerBound, hangupPos.lowerBound, "Chat goes before the hangup, which stays last")
    }

    /// The chat host and its cover never reach into the call: no video pipeline, no capture session, no renderers, no audio
    /// session, no hangup, mute or speaker. They present a chat and nothing else.
    func testTheChatHostDoesNotTouchTheCall() throws {
        let host = try code("QAudionApp/Views/Call/InCallChatCover.swift")
        for forbidden in [
            "videoPipeline", "AVCaptureSession", "RTCVideoTrack", "RTCMTLVideoView", "startVideoPipeline", "stopVideoPipeline",
            "AVAudioSession", "CallKit", "endCall", "setMuted", "setSpeaker", "setLocalCameraEnabled", "startScreenShare",
            "stopScreenShare", "callService",
        ] {
            XCTAssertFalse(host.contains(forbidden), "the chat host must not touch the call: found \(forbidden)")
        }
    }

    /// The camera of the chat has ONE entry (the "take a photo" tap) and it goes through the refusal.
    func testTakingAPhotoGoesThroughTheCameraRefusal() throws {
        let chat = try code("QAudionApp/Views/Chat/ChatDetailScreen.swift")
        XCTAssertEqual(occurrences(of: "showCameraPicker = true", in: chat), 1, "only one place may open the camera picker")
        XCTAssertTrue(chat.contains("private func handleTakePhotoTap() { if let blocked = callCameraBlock { blocked() } else { showCameraPicker = true } }"))
        XCTAssertTrue(chat.contains("InCallChatPolicy.cameraCaptureBlocked(inCall: appState.isInCall, videoCall: appState.isVideoCall)"))
        XCTAssertTrue(chat.contains("Button { handleTakePhotoTap() } label: { Label(\"Scatta foto\""))
    }
}
