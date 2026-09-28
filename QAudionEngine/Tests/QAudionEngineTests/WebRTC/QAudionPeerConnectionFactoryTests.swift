import XCTest
#if canImport(WebRTC)
import WebRTC
#endif
@testable import QAudionEngine

final class QAudionPeerConnectionFactoryTests: XCTestCase {
    #if canImport(WebRTC)
    func testFactoryIsLazyAndIdempotent() async {
        let f1 = await QAudionPeerConnectionFactory.shared.factory()
        let f2 = await QAudionPeerConnectionFactory.shared.factory()
        XCTAssertTrue(f1 === f2, "factory must be a singleton")
    }

    /// W-PERSISTENTFACTORY (2026-09-09) — the whole redesign's correctness
    /// rests on `sharedFactory()` returning the SAME factory+ADM across
    /// repeated calls, not a fresh pair each time (the old, now-removed
    /// per-call `createFactory()` behavior). Pins that guarantee directly.
    func testSharedFactoryReturnsSameFactoryAndAdmAcrossCalls() async {
        let first = await QAudionPeerConnectionFactory.shared.sharedFactory()
        let second = await QAudionPeerConnectionFactory.shared.sharedFactory()
        XCTAssertTrue(first.factory === second.factory, "factory must persist across calls")
        XCTAssertTrue(first.audioProcessingModule === second.audioProcessingModule, "ADM must persist across calls")
    }

    /// W-ADMWEDGERESET — the safety-net counterpart: after a forced reset,
    /// the NEXT `sharedFactory()` call must rebuild rather than keep
    /// returning the (potentially wedged) prior instance.
    func testResetForWedgeRecoveryForcesRebuildOnNextCall() async {
        let before = await QAudionPeerConnectionFactory.shared.sharedFactory()
        QAudionPeerConnectionFactory.shared.resetForWedgeRecovery()
        let after = await QAudionPeerConnectionFactory.shared.sharedFactory()
        XCTAssertFalse(before.factory === after.factory, "resetForWedgeRecovery must force a fresh factory")
        XCTAssertFalse(before.audioProcessingModule === after.audioProcessingModule, "resetForWedgeRecovery must force a fresh ADM")
    }

    /// W-KEYLOGGATE (2026-09-24) — WebRTC's INFO-level native prints include
    /// derived key material (frame_crypto_transformer.cc), and whatever the
    /// debug (stderr) severity lets through ends up in the uploaded app log.
    /// Guards against lowering it back to `.info` (or below) by accident.
    func testStderrDebugLogLevelStaysAtWarningOrAbove() {
        let level = QAudionPeerConnectionFactory.stderrDebugLogLevel
        XCTAssertNotEqual(level, .info)
        XCTAssertNotEqual(level, .verbose)
        XCTAssertGreaterThanOrEqual(level.rawValue, RTCLoggingSeverity.warning.rawValue)
    }

    func testDefaultConfigurationHasUnifiedPlan() {
        let cfg = QAudionPeerConnectionFactory.defaultConfiguration(iceServers: [])
        XCTAssertEqual(cfg.sdpSemantics, .unifiedPlan)
        XCTAssertEqual(cfg.bundlePolicy, .maxBundle)
        XCTAssertEqual(cfg.rtcpMuxPolicy, .require)
        XCTAssertEqual(cfg.continualGatheringPolicy, .gatherContinually)
    }

    /// W-NATIVESRTPGATE (this task) — with no `nativeSrtpEnabledLocally`
    /// argument (every existing call site before this task), the extra
    /// native-SRTP-only fields must NOT be touched: a normal call's
    /// RTCConfiguration stays byte-for-byte what it was before this task.
    /// Compared against a fresh `RTCConfiguration()` rather than hard-coded
    /// values: this SDK build returns a non-nil default `cryptoOptions`
    /// (CI, 2026-09-26), so "untouched" means "same as the SDK default".
    func testDefaultConfigurationWithNativeSrtpDisabled_leavesTheNativeSrtpFieldsAtSdkDefaults() {
        let cfg = QAudionPeerConnectionFactory.defaultConfiguration(iceServers: [], nativeSrtpEnabledLocally: false)
        let sdkDefault = RTCConfiguration()
        XCTAssertEqual(cfg.cryptoOptions == nil, sdkDefault.cryptoOptions == nil)
        if let got = cfg.cryptoOptions, let def = sdkDefault.cryptoOptions {
            XCTAssertEqual(got.srtpEnableGcmCryptoSuites, def.srtpEnableGcmCryptoSuites)
            XCTAssertEqual(got.srtpEnableAes128Sha1_32CryptoCipher, def.srtpEnableAes128Sha1_32CryptoCipher)
            XCTAssertEqual(got.srtpEnableEncryptedRtpHeaderExtensions, def.srtpEnableEncryptedRtpHeaderExtensions)
        }
        XCTAssertEqual(cfg.tcpCandidatePolicy, sdkDefault.tcpCandidatePolicy)
        XCTAssertEqual(cfg.audioJitterBufferMaxPackets, sdkDefault.audioJitterBufferMaxPackets)
        XCTAssertEqual(cfg.audioJitterBufferFastAccelerate, sdkDefault.audioJitterBufferFastAccelerate)
    }

    /// W-NATIVESRTPGATE — with the flag true, every best-practice parameter
    /// this task adds must actually be set.
    ///
    /// N1 (network-resilience-max) — 17, not the old 50: ~1s of buffering
    /// headroom at 60ms ptime (matching Riferimento A's own 1s cap), down
    /// from ~3s. See `defaultConfiguration`'s own doc for the full rationale.
    func testDefaultConfigurationWithNativeSrtpEnabled_appliesTheBestPracticeParameters() {
        let cfg = QAudionPeerConnectionFactory.defaultConfiguration(iceServers: [], nativeSrtpEnabledLocally: true)
        XCTAssertNotNil(cfg.cryptoOptions)
        XCTAssertEqual(cfg.tcpCandidatePolicy, .disabled)
        XCTAssertEqual(cfg.audioJitterBufferMaxPackets, 17)
        XCTAssertFalse(cfg.audioJitterBufferFastAccelerate)
        // N5 (network-resilience-max) — the DSCP master switch that
        // `RTCRtpEncodingParameters.networkPriority` (set on the native audio
        // sender, `QAudionPeerConnectionTests`) requires to have any effect.
        XCTAssertTrue(cfg.enableDscp)
    }

    /// N1 (network-resilience-max) — the disabled path (every ordinary call)
    /// must keep the SDK's own default jitter-buffer cap untouched: this
    /// task's 17-packet cap is scoped to the native-SRTP branch only, same
    /// discipline as every other field `testDefaultConfigurationWithNativeSrtpDisabled_leavesTheNativeSrtpFieldsAtSdkDefaults`
    /// already pins.
    func testDefaultConfigurationWithNativeSrtpDisabled_enableDscpStaysAtSdkDefault() {
        let cfg = QAudionPeerConnectionFactory.defaultConfiguration(iceServers: [], nativeSrtpEnabledLocally: false)
        let sdkDefault = RTCConfiguration()
        XCTAssertEqual(cfg.enableDscp, sdkDefault.enableDscp)
    }

    func testIceServerConversionFromRelayServers() {
        let relays: [RelayServer] = [
            RelayServer(urls: ["turn:turn.example:3478"], username: "u", credential: "c", ttl: 1800),
            RelayServer(urls: ["stun:stun.example:3478"], username: nil, credential: nil, ttl: 3600),
        ]
        let iceServers = QAudionPeerConnectionFactory.iceServers(from: relays)
        XCTAssertEqual(iceServers.count, 2)
        XCTAssertEqual(iceServers[0].urlStrings, ["turn:turn.example:3478"])
        XCTAssertEqual(iceServers[0].username, "u")
        XCTAssertEqual(iceServers[0].credential, "c")
        XCTAssertEqual(iceServers[1].urlStrings, ["stun:stun.example:3478"])
    }
    #else
    func testWebRTCNotAvailableInThisTarget() {
        XCTAssertTrue(true, "WebRTC framework not available in this target — skipping")
    }
    #endif
}
