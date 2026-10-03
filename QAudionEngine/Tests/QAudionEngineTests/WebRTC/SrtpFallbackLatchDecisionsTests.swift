import XCTest
@testable import QAudionEngine

/// W-FALLBACKLATCH (2026-10-03) — pins the three fences that keep the native-audio-srtp
/// fallback latch from being set for a call that is over, or surviving into the next one.
///
/// Field sequence (two iOS devices, 1.0.1206): the peer hung up; `AppState.endCall` reset the
/// latch in `CallService.teardownAudioStack`; the controller's still-sleeping engage task then
/// fired (the PeerConnection closes later, by design) and re-set the latch with only a
/// `!audioSrtpFallbackActive` guard in front of it; the next incoming call kept that latch
/// across its answer-time teardown, `NativeSenderMuteDecisions.shouldMute` came out `true`,
/// the legacy engine started on a native call and the callee heard nothing.
///
/// `FallbackLatchSim` is a faithful, minimal model of exactly those pieces of `CallService`
/// (generation bump + latch reset at end of call, the engage guard, the answer-time latch
/// decision, the mute formula), built ONLY from the helpers the real code calls. The wiring
/// half (that the real code calls them, in the right places) is in
/// `SrtpFallbackLatchWiringTests`.
final class SrtpFallbackLatchDecisionsTests: XCTestCase {

    private typealias Verdict = SrtpFallbackLatchDecisions.EngageVerdict

    /// The slice of `CallService` the field failure ran through.
    private final class FallbackLatchSim {
        var generation = 0
        var activeCallId: String?
        var latch = false
        var tag: SrtpFallbackLatchDecisions.LatchTag?
        var peerAnswered = false
        var userMuted = false

        func beginCall(id: String) { activeCallId = id }

        /// `AppState.endCall` -> `CallService.endCall`: generation bump, then the audio-stack
        /// teardown with the latch reset. The call id stays readable for a moment
        /// (AppState drops it later), which is why liveness alone is not the only fence.
        func endCall(clearsCallId: Bool) {
            generation += 1
            latch = false
            tag = nil
            peerAnswered = false
            if clearsCallId { activeCallId = nil }
        }

        /// `CallService.engageAudioSrtpFallback(capturedGeneration:)`.
        @discardableResult
        func engage(capturedGeneration: Int) -> Verdict {
            let verdict = SrtpFallbackLatchDecisions.engageVerdict(
                callLive: activeCallId != nil,
                capturedGeneration: capturedGeneration,
                currentGeneration: generation,
                alreadyActive: latch)
            if verdict == .engage {
                latch = true
                tag = SrtpFallbackLatchDecisions.LatchTag(generation: generation, callId: activeCallId)
            }
            return verdict
        }

        /// `CallService.activateIncomingCallAudio`'s latch decision (the teardown that follows
        /// keeps whatever latch is left), then the callee answer-time mute (site 1).
        func answerIncoming(callId: String) -> Bool {
            activeCallId = callId
            if latch, !SrtpFallbackLatchDecisions.latchHonouredAtAnswer(
                tag: tag, answeringCallId: activeCallId, currentGeneration: generation) {
                latch = false
                tag = nil
            }
            peerAnswered = true
            return NativeSenderMuteDecisions.shouldMute(
                peerAnswered: peerAnswered, userMuted: userMuted, fallbackActive: latch)
        }
    }

    // MARK: - (1) engage fences

    /// THE field case: the call ended, then the controller's task fired.
    func test_lateEngageAfterEndCall_isIgnored() {
        let sim = FallbackLatchSim()
        sim.beginCall(id: "aaaaaaaa-1111")
        let wired = sim.generation
        sim.endCall(clearsCallId: false)          // id still readable: the generation fence
        XCTAssertEqual(sim.engage(capturedGeneration: wired), .staleGeneration)
        XCTAssertFalse(sim.latch, "a late engage must not re-latch a torn-down call")
        sim.endCall(clearsCallId: true)           // id gone: the liveness fence
        XCTAssertEqual(sim.engage(capturedGeneration: wired), .noCallLive)
        XCTAssertFalse(sim.latch)
    }

    func test_engageWithNoLiveCall_isIgnoredEvenForTheCurrentGeneration() {
        XCTAssertEqual(
            SrtpFallbackLatchDecisions.engageVerdict(
                callLive: false, capturedGeneration: 4, currentGeneration: 4, alreadyActive: false),
            .noCallLive)
    }

    /// A callback wired for call A must not latch call B, even when B is live.
    func test_engageForAnOlderGeneration_isIgnored() {
        let sim = FallbackLatchSim()
        sim.beginCall(id: "aaaaaaaa-1111")
        let wiredForA = sim.generation
        sim.endCall(clearsCallId: true)
        sim.beginCall(id: "bbbbbbbb-2222")
        XCTAssertEqual(sim.engage(capturedGeneration: wiredForA), .staleGeneration)
        XCTAssertFalse(sim.latch)
    }

    func test_unknownCapturedGeneration_skipsOnlyTheGenerationFence() {
        XCTAssertEqual(
            SrtpFallbackLatchDecisions.engageVerdict(
                callLive: true, capturedGeneration: -1, currentGeneration: 9, alreadyActive: false),
            .engage, "an unprovable generation must not mute a live call")
        XCTAssertEqual(
            SrtpFallbackLatchDecisions.engageVerdict(
                callLive: false, capturedGeneration: -1, currentGeneration: 9, alreadyActive: false),
            .noCallLive)
    }

    /// A genuine in-call engage still latches, still mutes the native sender (so the legacy
    /// path can take over) and a repeat request stays a silent no-op.
    func test_legitimateInCallEngage_stillMutesAndFailsOver() {
        let sim = FallbackLatchSim()
        sim.beginCall(id: "aaaaaaaa-1111")
        sim.peerAnswered = true
        let wired = sim.generation
        XCTAssertEqual(sim.engage(capturedGeneration: wired), .engage)
        XCTAssertTrue(sim.latch)
        XCTAssertTrue(
            NativeSenderMuteDecisions.shouldMute(
                peerAnswered: sim.peerAnswered, userMuted: false, fallbackActive: sim.latch),
            "the engage must release the native sender")
        XCTAssertEqual(sim.engage(capturedGeneration: wired), .alreadyActive)
    }

    // MARK: - (3) the latch kept across the answer-time teardown

    /// The user-visible bug: a latch left by call A must not mute call B's answer.
    func test_staleLatchFromCallA_doesNotMuteCallBsAnswer() {
        let sim = FallbackLatchSim()
        sim.beginCall(id: "aaaaaaaa-1111")
        sim.peerAnswered = true
        XCTAssertEqual(sim.engage(capturedGeneration: sim.generation), .engage)
        // Call A ends WITHOUT the latch being reset (any path that leaves it behind).
        sim.generation += 1
        sim.activeCallId = nil
        XCTAssertTrue(sim.latch)
        let wantMute = sim.answerIncoming(callId: "bbbbbbbb-2222")
        XCTAssertFalse(wantMute, "want=0 at site=1: B's native sender must be unmuted at answer")
        XCTAssertFalse(sim.latch)
        XCTAssertNil(sim.tag)
    }

    /// The whole field sequence end to end: late engage after teardown, then the next call.
    func test_fieldSequence_lateEngageThenNextIncomingCall_answersUnmuted() {
        let sim = FallbackLatchSim()
        sim.beginCall(id: "aaaaaaaa-1111")
        sim.peerAnswered = true
        let wired = sim.generation
        sim.endCall(clearsCallId: false)
        sim.engage(capturedGeneration: wired)     // the late task
        XCTAssertFalse(sim.answerIncoming(callId: "bbbbbbbb-2222"))
    }

    /// The reason the latch survives the answer teardown at all: a ringing-time engage of
    /// THE call being answered must still be honoured, even if an unrelated `endCall` (a
    /// busy bounce of another call) bumped the generation in between.
    func test_ringingTimeEngageOfTheAnsweredCall_isKept() {
        let sim = FallbackLatchSim()
        sim.beginCall(id: "bbbbbbbb-2222")
        XCTAssertEqual(sim.engage(capturedGeneration: sim.generation), .engage)
        sim.generation += 1                       // unrelated endCall
        XCTAssertTrue(
            sim.answerIncoming(callId: "BBBBBBBB-2222"),
            "same call (case-insensitive id): the sender stays released until recover")
        XCTAssertTrue(sim.latch)
    }

    func test_latchTag_keepsOnlyAnEightCharLowercasePrefix() {
        let tag = SrtpFallbackLatchDecisions.LatchTag(
            generation: 3, callId: "ABCDEF12-3456-7890-ABCD-EF1234567890")
        XCTAssertEqual(tag.callIdPrefix, "abcdef12")
        XCTAssertEqual(tag.generation, 3)
        XCTAssertNil(SrtpFallbackLatchDecisions.LatchTag(generation: 3, callId: nil).callIdPrefix)
        XCTAssertNil(SrtpFallbackLatchDecisions.LatchTag(generation: 3, callId: "").callIdPrefix)
    }

    func test_latchWithoutATag_isNeverHonoured() {
        XCTAssertFalse(SrtpFallbackLatchDecisions.latchHonouredAtAnswer(
            tag: nil, answeringCallId: "bbbbbbbb-2222", currentGeneration: 1))
    }

    func test_whenAnIdIsUnknown_theGenerationDecides() {
        let tag = SrtpFallbackLatchDecisions.LatchTag(generation: 5, callId: nil)
        XCTAssertTrue(SrtpFallbackLatchDecisions.latchHonouredAtAnswer(
            tag: tag, answeringCallId: "bbbbbbbb-2222", currentGeneration: 5))
        XCTAssertFalse(SrtpFallbackLatchDecisions.latchHonouredAtAnswer(
            tag: tag, answeringCallId: "bbbbbbbb-2222", currentGeneration: 6))
        let idTag = SrtpFallbackLatchDecisions.LatchTag(generation: 5, callId: "aaaaaaaa-1111")
        XCTAssertFalse(SrtpFallbackLatchDecisions.latchHonouredAtAnswer(
            tag: idTag, answeringCallId: nil, currentGeneration: 6))
        XCTAssertTrue(SrtpFallbackLatchDecisions.latchHonouredAtAnswer(
            tag: idTag, answeringCallId: "", currentGeneration: 5))
    }

    func test_engageVerdictCodes_areTheLoggedWhyCodes() {
        XCTAssertEqual(Verdict.engage.rawValue, 0)
        XCTAssertEqual(Verdict.alreadyActive.rawValue, 1)
        XCTAssertEqual(Verdict.noCallLive.rawValue, 2)
        XCTAssertEqual(Verdict.staleGeneration.rawValue, 3)
    }

    // MARK: - (2) the controller's debounce task

    /// A controller whose call is closed engages nothing, however long ICE has been bad.
    func test_closedCall_engagesNothing_andStopsWaiting() {
        let debounce = SrtpFallbackDecisions.fallbackEngageDebounceMs
        XCTAssertTrue(SrtpFallbackDecisions.shouldEngageFallback(
            usingNativeAudioSrtp: true, iceBad: true, iceBadSinceMs: 1_000,
            nowMs: 1_000 + debounce, fallbackAlreadyEngaged: false, callClosed: false))
        XCTAssertFalse(SrtpFallbackDecisions.shouldEngageFallback(
            usingNativeAudioSrtp: true, iceBad: true, iceBadSinceMs: 1_000,
            nowMs: 1_000 + 10 * debounce, fallbackAlreadyEngaged: false, callClosed: true))
        XCTAssertTrue(SrtpFallbackDecisions.shouldKeepWaitingToEngage(
            streakAlive: true, fallbackAlreadyEngaged: false, callClosed: false))
        XCTAssertFalse(SrtpFallbackDecisions.shouldKeepWaitingToEngage(
            streakAlive: true, fallbackAlreadyEngaged: false, callClosed: true))
    }

    /// The new parameter defaults to "not closed": every pre-existing caller is unchanged.
    func test_callClosedDefaultsToOpen() {
        let debounce = SrtpFallbackDecisions.fallbackEngageDebounceMs
        XCTAssertTrue(SrtpFallbackDecisions.shouldEngageFallback(
            usingNativeAudioSrtp: true, iceBad: true, iceBadSinceMs: 1_000,
            nowMs: 1_000 + debounce, fallbackAlreadyEngaged: false))
        XCTAssertTrue(SrtpFallbackDecisions.shouldKeepWaitingToEngage(
            streakAlive: true, fallbackAlreadyEngaged: false))
    }

    // MARK: - (4) transport split flag

    func test_transportSplit_none_whenNativeCarriedTheCall() {
        XCTAssertEqual(
            AudioTransportSplit.classify(
                nativeNegotiated: true, localLegacyEngineStarted: false,
                fallbackEverEngaged: false, peerLegacyRxFrames: 0),
            .none)
    }

    /// The field case, seen from the silent side: legacy engine on a native call, no engage.
    func test_transportSplit_localLegacyUnexplained() {
        XCTAssertEqual(
            AudioTransportSplit.classify(
                nativeNegotiated: true, localLegacyEngineStarted: true,
                fallbackEverEngaged: false, peerLegacyRxFrames: 0),
            .localLegacyUnexplained)
    }

    /// The field case, seen from the healthy side: legacy frames from the peer injected into
    /// the native playout.
    func test_transportSplit_peerLegacy() {
        XCTAssertEqual(
            AudioTransportSplit.classify(
                nativeNegotiated: true, localLegacyEngineStarted: false,
                fallbackEverEngaged: false, peerLegacyRxFrames: 12),
            .peerLegacy)
    }

    func test_transportSplit_both() {
        XCTAssertEqual(
            AudioTransportSplit.classify(
                nativeNegotiated: true, localLegacyEngineStarted: true,
                fallbackEverEngaged: false, peerLegacyRxFrames: 1),
            .both)
    }

    /// A legitimate fallback explains the local legacy engine; a legacy-by-negotiation call is
    /// never a split.
    func test_transportSplit_isNotRaisedByALegitimateFallbackOrALegacyCall() {
        XCTAssertEqual(
            AudioTransportSplit.classify(
                nativeNegotiated: true, localLegacyEngineStarted: true,
                fallbackEverEngaged: true, peerLegacyRxFrames: 0),
            .none)
        XCTAssertEqual(
            AudioTransportSplit.classify(
                nativeNegotiated: false, localLegacyEngineStarted: true,
                fallbackEverEngaged: false, peerLegacyRxFrames: 40),
            .none)
    }
}
