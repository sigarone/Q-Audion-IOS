import XCTest
@testable import QAudionEngine

final class GroupMediaRecoveryPolicyTests: XCTestCase {

    func testSecurityFailuresEndTheMediaImmediately() {
        var policy = GroupMediaRecoveryPolicy()
        XCTAssertEqual(policy.handle(.securityFailure, nowMs: 0), .fail(.transportPolicy))
        XCTAssertTrue(GroupCallMediaError.transportPolicy.isFatal)
    }

    func testARetryableJanusErrorGetsExactlyOneAutomaticMediaJoin() {
        var policy = GroupMediaRecoveryPolicy()
        XCTAssertEqual(policy.handle(.retryableJanusError(433), nowMs: 0), .sendMediaJoin(delayMs: 0))
        XCTAssertEqual(policy.handle(.retryableJanusError(433), nowMs: 500), .fail(.mediaLost))
    }

    func testAFatalJanusErrorIsShown() {
        var policy = GroupMediaRecoveryPolicy()
        XCTAssertEqual(policy.handle(.fatalJanusError(436), nowMs: 0), .fail(.other("janus_436")))
    }

    func testRejoinsBackOffAndAreCappedAtThreeInAMinute() {
        var policy = GroupMediaRecoveryPolicy()
        XCTAssertEqual(policy.handle(.needsRejoin("pc_failed"), nowMs: 1_000), .sendMediaRejoin(reason: "pc_failed", delayMs: 500))
        XCTAssertEqual(policy.handle(.needsRejoin("pc_failed"), nowMs: 5_000), .sendMediaRejoin(reason: "pc_failed", delayMs: 1_000))
        XCTAssertEqual(policy.handle(.needsRejoin("ws_lost"), nowMs: 9_000), .sendMediaRejoin(reason: "ws_lost", delayMs: 2_000))
        XCTAssertEqual(policy.handle(.needsRejoin("ws_lost"), nowMs: 13_000), .fail(.mediaLost))
    }

    func testOldRejoinsLeaveTheWindow() {
        var policy = GroupMediaRecoveryPolicy()
        _ = policy.handle(.needsRejoin("a"), nowMs: 0)
        _ = policy.handle(.needsRejoin("a"), nowMs: 1_000)
        _ = policy.handle(.needsRejoin("a"), nowMs: 2_000)
        XCTAssertEqual(policy.handle(.needsRejoin("b"), nowMs: 70_000), .sendMediaRejoin(reason: "b", delayMs: 500))
    }

    func testAStableCallForgivesEarlierFailures() {
        var policy = GroupMediaRecoveryPolicy()
        _ = policy.handle(.needsRejoin("a"), nowMs: 0)
        _ = policy.handle(.needsRejoin("a"), nowMs: 1_000)
        _ = policy.handle(.needsRejoin("a"), nowMs: 2_000)
        policy.mediaBecameActive(nowMs: 3_000)
        XCTAssertEqual(policy.handle(.needsRejoin("later"), nowMs: 40_000), .sendMediaRejoin(reason: "later", delayMs: 500),
                       "30 s of stable media resets the budget")
    }

    func testAnUnstableCallIsNotForgiven() {
        var policy = GroupMediaRecoveryPolicy()
        _ = policy.handle(.needsRejoin("a"), nowMs: 0)
        _ = policy.handle(.needsRejoin("a"), nowMs: 1_000)
        _ = policy.handle(.needsRejoin("a"), nowMs: 2_000)
        policy.mediaBecameActive(nowMs: 3_000)
        XCTAssertEqual(policy.handle(.needsRejoin("soon"), nowMs: 10_000), .fail(.mediaLost))
    }

    func testMediaMovedRejoinsWithAPlainMediaJoinAndIsBounded() {
        var policy = GroupMediaRecoveryPolicy()
        for _ in 0..<5 { XCTAssertEqual(policy.handle(.mediaMoved, nowMs: 0), .sendMediaJoin(delayMs: 0)) }
        XCTAssertEqual(policy.handle(.mediaMoved, nowMs: 0), .fail(.mediaLost))
    }

    func testUnavailableReasonsMapToClearErrors() {
        var policy = GroupMediaRecoveryPolicy()
        XCTAssertEqual(policy.handle(.mediaUnavailable(.noNode), nowMs: 0), .fail(.noNode))
        XCTAssertEqual(policy.handle(.mediaUnavailable(.roomCreateFailed), nowMs: 0), .fail(.roomCreateFailed))
        XCTAssertEqual(policy.handle(.mediaUnavailable(.notMember), nowMs: 0), .fail(.notMember))
        XCTAssertEqual(policy.handle(.mediaUnavailable(.full), nowMs: 0), .fail(.full))
        XCTAssertEqual(policy.handle(.mediaUnavailable(.other("x")), nowMs: 0), .fail(.other("x")))
    }

    func testThrottledJoinsAreWaitedOutThenGiveUp() {
        var policy = GroupMediaRecoveryPolicy()
        for _ in 0..<3 { XCTAssertEqual(policy.handle(.mediaUnavailable(.throttled), nowMs: 0), .sendMediaJoin(delayMs: 2_000)) }
        XCTAssertEqual(policy.handle(.mediaUnavailable(.throttled), nowMs: 0), .fail(.mediaLost))
    }

    func testCameraErrorsAreNotFatal() {
        XCTAssertFalse(GroupCallMediaError.cameraPermissionDenied.isFatal)
        XCTAssertFalse(GroupCallMediaError.cameraUnavailable.isFatal)
        XCTAssertTrue(GroupCallMediaError.mediaLost.isFatal)
        XCTAssertTrue(GroupCallMediaError.full.isFatal)
    }
}

final class GroupMediaRecoveryRoomFullTests: XCTestCase {

    func testJanusRoomFullIsTheFullErrorNotAGenericOne() {
        var policy = GroupMediaRecoveryPolicy()
        XCTAssertEqual(policy.handle(.fatalJanusError(432), nowMs: 0), .fail(.full))
        XCTAssertEqual(policy.handle(.fatalJanusError(436), nowMs: 0), .fail(.other("janus_436")))
    }
}

#if canImport(WebRTC)
final class GroupPublisherLayerCapTests: XCTestCase {

    /// libwebrtc drops the top simulcast layer for a source below about 720p.
    func testTheCaptureHeightDecidesHowManyLayersItCanFeed() {
        XCTAssertEqual(GroupPublisherPeer.layerCap(forHeight: 1080), 3)
        XCTAssertEqual(GroupPublisherPeer.layerCap(forHeight: 720), 3)
        XCTAssertEqual(GroupPublisherPeer.layerCap(forHeight: 540), 2)
        XCTAssertEqual(GroupPublisherPeer.layerCap(forHeight: 360), 2)
        XCTAssertEqual(GroupPublisherPeer.layerCap(forHeight: 240), 1)
    }
}
#endif

final class GroupSpeakingDetectorTests: XCTestCase {

    func testAboveThresholdIsSpeakingAndLoudestComesFirst() {
        var detector = GroupSpeakingDetector()
        let speaking = detector.update(levels: ["a": 0.1, "b": 0.3, "c": 0.001], nowMs: 0)
        XCTAssertEqual(speaking, ["b", "a"])
    }

    func testTheHoldTimeKeepsAMemberSpeakingBetweenWords() {
        var detector = GroupSpeakingDetector()
        _ = detector.update(levels: ["a": 0.2], nowMs: 0)
        XCTAssertEqual(detector.update(levels: ["a": 0.0], nowMs: 1_000), ["a"])
        XCTAssertEqual(detector.update(levels: ["a": 0.0], nowMs: 1_300), [])
    }

    func testAMemberWhoLeftStopsSpeakingAtOnce() {
        var detector = GroupSpeakingDetector()
        _ = detector.update(levels: ["a": 0.2], nowMs: 0)
        XCTAssertEqual(detector.update(levels: [:], nowMs: 100), [])
    }

    func testResetForgetsEveryone() {
        var detector = GroupSpeakingDetector()
        _ = detector.update(levels: ["a": 0.2], nowMs: 0)
        detector.reset()
        XCTAssertEqual(detector.update(levels: ["a": 0.0], nowMs: 10), [])
    }
}

final class GroupPublishPolicyTests: XCTestCase {

    func testNominalPublishesAllThreeLayers() {
        XCTAssertEqual(GroupPublishPolicy.decide(thermal: .nominal, lowPowerMode: false, congestionSteps: 0).activeLayers, 3)
        XCTAssertEqual(GroupPublishPolicy.decide(thermal: .fair, lowPowerMode: false, congestionSteps: 0).activeLayers, 3)
    }

    func testThermalAndBatteryPressureDropTheHighLayerFirst() {
        XCTAssertEqual(GroupPublishPolicy.decide(thermal: .serious, lowPowerMode: false, congestionSteps: 0).activeLayers, 2)
        XCTAssertEqual(GroupPublishPolicy.decide(thermal: .critical, lowPowerMode: false, congestionSteps: 0).activeLayers, 1)
        XCTAssertEqual(GroupPublishPolicy.decide(thermal: .nominal, lowPowerMode: true, congestionSteps: 0).activeLayers, 2)
    }

    func testCongestionStepsDownToLThenStopsTheVideoNeverTheAudio() {
        XCTAssertEqual(GroupPublishPolicy.decide(thermal: .nominal, lowPowerMode: false, congestionSteps: 1).activeLayers, 2)
        XCTAssertEqual(GroupPublishPolicy.decide(thermal: .nominal, lowPowerMode: false, congestionSteps: 2).activeLayers, 1)
        let stopped = GroupPublishPolicy.decide(thermal: .nominal, lowPowerMode: false, congestionSteps: 3)
        XCTAssertEqual(stopped.activeLayers, 0)
        XCTAssertFalse(stopped.publishVideo)
        XCTAssertEqual(GroupPublishPolicy.decide(thermal: .critical, lowPowerMode: true, congestionSteps: 9).activeLayers, 0)
    }

    func testPressureAndCongestionCompose() {
        XCTAssertEqual(GroupPublishPolicy.decide(thermal: .serious, lowPowerMode: false, congestionSteps: 1).activeLayers, 1)
    }
}

final class GroupAudioUnitDecisionsTests: XCTestCase {

    func testNothingHappensBeforeTheGroupAudioBegan() {
        XCTAssertEqual(GroupAudioUnitDecisions.action(begun: false, source: .callKit, callKitAlreadySeen: false), .ignore)
    }

    func testNoSessionNoUnit() {
        XCTAssertEqual(GroupAudioUnitDecisions.action(begun: true, source: .notActivated, callKitAlreadySeen: false), .ignore)
    }

    func testCallKitAndSelfManagedActivationsEnableAtOnce() {
        XCTAssertEqual(GroupAudioUnitDecisions.action(begun: true, source: .callKit, callKitAlreadySeen: false), .enableNow)
        XCTAssertEqual(GroupAudioUnitDecisions.action(begun: true, source: .selfManaged, callKitAlreadySeen: false), .enableNow)
    }

    func testAnActivationThatStillExpectsCallKitWaitsForIt() {
        XCTAssertEqual(GroupAudioUnitDecisions.action(begun: true, source: .selfExpectingCallKit, callKitAlreadySeen: false),
                       .enableAfterCallKitWait)
        XCTAssertEqual(GroupAudioUnitDecisions.action(begun: true, source: .selfExpectingCallKit, callKitAlreadySeen: true), .enableNow)
    }

    func testTheGroupReasonsHaveTheirOwnGateCodes() {
        XCTAssertEqual(NativeAudioUnitGateDecisions.ChangeReason.groupEnable.rawValue, 9)
        XCTAssertEqual(NativeAudioUnitGateDecisions.ChangeReason.groupEnd.rawValue, 10)
    }
}

final class GroupTelemetryTests: XCTestCase {

    func testIdsAreCutToEightCharacters() {
        XCTAssertEqual(GroupTelemetry.id8(GroupCallFixtures.pseudoA), "a1a1a1a1")
        XCTAssertEqual(GroupTelemetry.id8("abc"), "abc")
    }

    func testEventShapes() {
        XCTAssertEqual(GroupTelemetry.mediaJoin(nodeId: "node-a", ms: 812).kind, "group.media_join")
        XCTAssertEqual(GroupTelemetry.mediaJoin(nodeId: "node-a", ms: 812).attrs["ms"] as? Int, 812)
        XCTAssertEqual(GroupTelemetry.pcState(.pub, state: "connected").attrs["pc"] as? String, "pub")
        XCTAssertEqual(GroupTelemetry.pcState(.sub, state: "failed").attrs["pc"] as? String, "sub")
        let transport = GroupTelemetry.transport(.init(tlsVersion: "FEFC", dtlsCipher: "TLS_AES_256_GCM_SHA384", srtpCipher: "AEAD_AES_256_GCM", candidateType: "relay"))
        XCTAssertEqual(transport.kind, "group.transport")
        XCTAssertEqual(transport.attrs["cand_type"] as? String, "relay")
        XCTAssertEqual(GroupTelemetry.transportPolicyViolation(.pub, fields: ["tls", "srtp"]).attrs["fields"] as? String, "tls,srtp")
        XCTAssertEqual(GroupTelemetry.dtlsPinMismatch(.sub).kind, "group.dtls_pin_mismatch")
        XCTAssertEqual(GroupTelemetry.e2ee(.missingKey, epoch: 7).attrs["event"] as? String, "missing_key")
        XCTAssertEqual(GroupTelemetry.e2ee(.keySent, epoch: 7).attrs["epoch"] as? Int, 7)
        XCTAssertEqual(GroupTelemetry.layer(mid: "1", from: 2, to: 1, reason: "loss").attrs["reason"] as? String, "loss")
        XCTAssertEqual(GroupTelemetry.rejoin(reason: "pc_failed").kind, "group.rejoin")
        XCTAssertEqual(GroupTelemetry.iceRestart(reason: "wifi_cell").kind, "group.ice_restart")
    }

    func testFreeTextIsBoundedSoNothingLongCanLeak() {
        let long = String(repeating: "x", count: 500)
        XCTAssertLessThanOrEqual((GroupTelemetry.rejoin(reason: long).attrs["reason"] as? String)?.count ?? 0, 24)
        XCTAssertLessThanOrEqual((GroupTelemetry.pcState(.pub, state: long).attrs["state"] as? String)?.count ?? 0, 16)
        XCTAssertLessThanOrEqual((GroupTelemetry.mediaJoin(nodeId: long, ms: 1).attrs["node"] as? String)?.count ?? 0, 16)
    }
}
