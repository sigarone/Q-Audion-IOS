import XCTest
@testable import QAudionEngine

/// W-FALLBACKLATCH (2026-10-03) — source-invariant guard for WHERE the fallback-latch fences
/// are wired. The pure rules are proven behaviourally in `SrtpFallbackLatchDecisionsTests`; what
/// those cannot prove is that the real code calls them at the right sites, and the sites are the
/// whole risk: `CallService`, `AppState` and the call controller need CallKit, AVAudioSession,
/// WebRTC and a live socket, none of which a plain test target has. Same choice as
/// `PskAdvertLatchWiringTests`.
///
/// Unlike that file, a missing source file or anchor is a FAILURE here, never a skip: a guard
/// that silently stops running is the failure mode this exists to prevent.
final class SrtpFallbackLatchWiringTests: XCTestCase {

    // MARK: - Source access (fail, never skip)

    /// Repo root = the nearest ancestor of this test file that holds `QAudionApp/AppState.swift`.
    private func repoRoot(file: StaticString = #filePath, line: UInt = #line) -> URL {
        var dir = URL(fileURLWithPath: "\(file)")
        for _ in 0..<10 {
            dir = dir.deletingLastPathComponent()
            let marker = dir.appendingPathComponent("QAudionApp/AppState.swift")
            if FileManager.default.fileExists(atPath: marker.path) { return dir }
        }
        XCTFail("repo root not found from \(file): the wiring guard cannot run", line: line)
        return dir
    }

    private func read(_ relative: String, line: UInt = #line) -> String {
        let url = repoRoot().appendingPathComponent(relative)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            XCTFail("cannot read \(relative): the wiring guard cannot run", line: line)
            return ""
        }
        XCTAssertFalse(text.isEmpty, "\(relative) is empty", line: line)
        return text.replacingOccurrences(of: "\r\n", with: "\n")
    }

    /// The text from the first `from` anchor to the next `to` anchor after it. Fails (and
    /// returns "") when either anchor is missing.
    private func slice(_ src: String, from: String, to: String, line: UInt = #line) -> String {
        guard let a = src.range(of: from) else {
            XCTFail("anchor not found: \(from)", line: line)
            return ""
        }
        guard let b = src.range(of: to, range: a.upperBound..<src.endIndex) else {
            XCTFail("end anchor not found after \(from): \(to)", line: line)
            return ""
        }
        return String(src[a.lowerBound..<b.lowerBound])
    }

    private func count(_ needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    private let controllerPath = "QAudionEngine/Sources/QAudionEngine/WebRTC/QAudionWebRtcCallController.swift"
    private let callServicePath = "QAudionApp/Services/CallService.swift"
    private let appStatePath = "QAudionApp/AppState.swift"

    // MARK: - (2) controller

    /// `closeSynchronously` cancels the engage task and clears the streak/engaged state BEFORE its
    /// early return (the Bug-C shape), so a controller closed mid-setup cannot leak it either.
    func test_closeSynchronously_cancelsTheEngageTask_andClearsTheStreak() {
        let src = read(controllerPath)
        let body = slice(src, from: "public func closeSynchronously() {", to: "guard peerConnection != nil else {")
        XCTAssertTrue(body.contains("intentionalShutdown = true"))
        XCTAssertTrue(body.contains("srtpFallbackTask?.cancel()"),
                      "closeSynchronously must cancel the SRTP-fallback debounce task")
        XCTAssertTrue(body.contains("srtpFallbackTask = nil"))
        XCTAssertTrue(body.contains("iceBadSinceMs = nil"), "the bad-ICE streak must be cleared")
        XCTAssertTrue(body.contains("srtpFallbackEngaged = false"), "the engaged flag must be cleared")
        XCTAssertTrue(body.contains("srtpFallbackEngagedAtMs = nil"))
    }

    /// The task body re-checks the shutdown latch (after its sleep) for BOTH decisions, and a
    /// closing controller never arms a new debounce.
    func test_engageTask_recheckesTheShutdownLatchBeforeCallingOut() {
        let src = read(controllerPath)
        let arm = slice(src, from: "private func armSrtpFallbackIfNeeded() {", to: "/// W-SRTPFALLBACK — the recover edge")
        XCTAssertEqual(count("callClosed: self.intentionalShutdown", in: arm), 2,
                       "both the engage decision and the keep-waiting decision must see the latch")
        let head = slice(arm, from: "private func armSrtpFallbackIfNeeded() {", to: "guard peerConnection?.usingNativeAudioSrtp")
        XCTAssertTrue(head.contains("guard !intentionalShutdown else { return }"),
                      "a closing controller must not arm a new engage debounce")
    }

    // MARK: - (1) + (3) CallService

    func test_engageAudioSrtpFallback_goesThroughTheVerdict_andTagsTheLatch() {
        let src = read(callServicePath)
        let body = slice(src, from: "public func engageAudioSrtpFallback(capturedGeneration: Int) {",
                         to: "public func recoverAudioSrtpFallback() {")
        XCTAssertTrue(body.contains("SrtpFallbackLatchDecisions.engageVerdict("))
        XCTAssertTrue(body.contains("capturedGeneration: capturedGeneration"))
        XCTAssertTrue(body.contains("currentGeneration: currentCallGeneration()"))
        XCTAssertTrue(body.contains("callLive: getCallId?() != nil"))
        XCTAssertTrue(body.contains("audiosrtpfb engage=0 why="),
                      "an ignored engage must leave a numeric trace")
        XCTAssertTrue(body.contains("SrtpFallbackLatchDecisions.LatchTag("),
                      "the latch must be tagged with the call that set it")
        // The ignore path returns BEFORE the latch is set.
        guard let verdictAt = body.range(of: "engageVerdict("),
              let setAt = body.range(of: "audioSrtpFallbackActive = true") else {
            return XCTFail("verdict or latch assignment missing")
        }
        XCTAssertLessThan(verdictAt.lowerBound, setAt.lowerBound)
    }

    /// No caller may bypass the generation: the parameterless form is gone.
    func test_noCallerEngagesWithoutAGeneration() {
        for path in [callServicePath, appStatePath] {
            // Code lines only: comments name the old parameterless form on purpose.
            let code = read(path)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            XCTAssertEqual(count("engageAudioSrtpFallback()", in: code), 0,
                           "\(path): engageAudioSrtpFallback must always carry a generation")
        }
    }

    /// The answer-time latch decision runs BEFORE the teardown that keeps the latch, and gets
    /// the generation snapshotted at entry.
    func test_activateIncomingCallAudio_decidesTheLatchBeforeTheAnswerTimeTeardown() {
        let src = read(callServicePath)
        let body = slice(src, from: "func activateIncomingCallAudio(engine: QAudionEngine,",
                         to: "teardownAudioStack(resetSrtpFallback: false, resetDcCounters: true)")
        XCTAssertTrue(body.contains("SrtpFallbackLatchDecisions.latchHonouredAtAnswer("))
        XCTAssertTrue(body.contains("tag: audioSrtpFallbackTag"))
        XCTAssertTrue(body.contains("currentGeneration: _savedGeneration"))
        XCTAssertTrue(body.contains("audiosrtpfb latch=0 stale=1"))
        XCTAssertTrue(body.contains("audioSrtpFallbackActive = false"),
                      "a latch that is not honoured must be cleared")
    }

    /// The latch and its tag are cleared together at end of call and on recover.
    func test_latchTag_isClearedWithTheLatch() {
        let src = read(callServicePath)
        let teardown = slice(src, from: "if resetSrtpFallback {", to: "// W-SLOTLOCK — nil the cross-thread reference slots")
        XCTAssertTrue(teardown.contains("audioSrtpFallbackTag = nil"))
        XCTAssertTrue(teardown.contains("srtpFallbackEverEngaged = false"))
        let recover = slice(src, from: "public func recoverAudioSrtpFallback() {", to: "/// W464 — CallKit activated the shared")
        XCTAssertTrue(recover.contains("audioSrtpFallbackTag = nil"))
    }

    // MARK: - (1) AppState wiring (caller + callee)

    func test_bothWiringSites_passTheGenerationCapturedWhenWired() {
        let src = read(appStatePath)
        XCTAssertEqual(count("engageAudioSrtpFallback(capturedGeneration: fallbackWiredGeneration)", in: src), 2,
                       "caller and callee wiring must both pass the captured generation")
        // Caller: the generation read before the OFFER. Callee: read at the top of the build.
        XCTAssertTrue(src.contains("let fallbackWiredGeneration: Int = offerCallGeneration"))
        XCTAssertTrue(src.contains("let fallbackWiredGeneration: Int = callService.currentCallGeneration()"))
    }

    // MARK: - (4) observability

    func test_audioCountsCarryTheCorrectedFallbackFlagAndTheTransportSplit() {
        let src = read(callServicePath)
        XCTAssertTrue(src.contains("\"fallback_fired\":  didActivateFallbackFired || srtpFallbackEverEngaged"))
        XCTAssertTrue(src.contains("\"srtp_fb_engaged\": srtpFallbackEverEngaged"))
        XCTAssertTrue(src.contains("\"transport_split\": _transportSplit"))
        XCTAssertTrue(src.contains("AudioTransportSplit.classify("))
    }

    /// Every `audiosrtpfb` shape the app emits must be in the shipper's vocabulary, or the line
    /// never reaches Loki (it was 11 letters long and unknown: the whole family was dropped).
    func test_shipperVocabularyCoversTheAudiosrtpfbFamily() {
        let script = read("scripts/ship-ios-logs.py")
        let vocab = slice(script, from: "APP_VOCAB = frozenset(\"\"\"", to: "\"\"\".split())")
        for word in ["audiosrtpfb", "engage", "recover", "admreset", "wedges", "latch", "split"] {
            XCTAssertTrue(
                vocab.split(whereSeparator: { $0.isWhitespace }).contains(Substring(word)),
                "ship-ios-logs.py APP_VOCAB lacks \(word)")
        }
    }
}
