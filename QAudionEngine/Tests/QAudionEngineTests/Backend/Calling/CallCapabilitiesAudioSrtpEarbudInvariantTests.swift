import XCTest
@testable import QAudionEngine

/// IOS-C4b — CI guard on the SRTP-audio path's structural properties,
/// deliberately NOT on ``CallCapabilities/audioSrtpSendEnabled``'s value.
/// Direct Swift port of Android's
/// `CallCapabilitiesAudioSrtpEarbudInvariantTest.kt` (AND-4(a)): that flag is
/// qualified in its own kdoc as an internal test kill switch, so a test that
/// fails whenever it is `false` would be wrong — it would block exactly the
/// safe-by-default posture the flag exists to allow.
///
/// What IS structural, and worth pinning here: ``CallCapabilities/localCaps``
/// applies its earbud-paired filter unconditionally AFTER the flag-gated
/// ``CallCapabilities/audioSrtpV1`` add to the base list — so the tag can
/// never survive into an earbud call's advertisement, whatever
/// ``CallCapabilities/audioSrtpSendEnabled`` is set to today or in the
/// future. Native RTP audio needs a FrameCryptor frame-content hook the
/// earbud's opaque sealed-relay design structurally cannot provide (see
/// ``CallCapabilities/audioSrtpV1``'s own doc), so this withholding is a
/// hardware fact, not a policy knob that could reasonably flip the way the
/// send kill switch does.
final class CallCapabilitiesAudioSrtpEarbudInvariantTests: XCTestCase {

    func test_earbudPaired_withholdsAudioSrtpV1_onAnActiveEarbudRelayCall() {
        let caps = CallCapabilities.localCaps(earbudActive: true, earbudPaired: true)
        XCTAssertFalse(
            caps.contains(CallCapabilities.audioSrtpV1),
            "native RTP audio requires a FrameCryptor hook the earbud's opaque relay cannot provide — must never be offered on an earbud call, independent of audioSrtpSendEnabled's current value"
        )
    }

    func test_earbudPaired_withholdsAudioSrtpV1_evenWhenTheEarbudIsNotYetTheActiveMediaPath() {
        // W-LONGPROFILE's gate keys on PAIRED, not ACTIVE (see localCaps's
        // doc on the earbudPaired parameter): an earbud adopted mid-call,
        // after this advertisement already went out, would retroactively
        // turn a true "I can receive this" statement into a lie — there is
        // no mechanism to withdraw a tag once sent. Same rule applies to
        // audioSrtpV1.
        let caps = CallCapabilities.localCaps(earbudActive: false, earbudPaired: true)
        XCTAssertFalse(
            caps.contains(CallCapabilities.audioSrtpV1),
            "the gate keys on PAIRED not ACTIVE — a paired-but-not-yet-active earbud must still withhold audioSrtpV1"
        )
    }

    func test_earbudPaired_withholdingOfAudioSrtpV1_isIndependentOfSovereignOnly() {
        // sovereignOnly only strips vkeyV1 (see localCaps's `base` init) —
        // confirms the two filters are orthogonal and neither masks a
        // broken earbud filter.
        let caps = CallCapabilities.localCaps(earbudActive: true, sovereignOnly: true, earbudPaired: true)
        XCTAssertFalse(caps.contains(CallCapabilities.audioSrtpV1))
    }

    func test_nonEarbudCaps_trackAudioSrtpSendEnabledsOwnValue_untouchedByTheEarbudFilter() {
        // Non-vacuity check for the three tests above: proves the earbud
        // filter is a real, scoped removal rather than audioSrtpV1 simply
        // never being present at all. Deliberately does NOT hardcode
        // `true`/`false` — it reads audioSrtpSendEnabled's CURRENT value (see
        // the class doc on why this suite never pins that flag), so this
        // stays correct whichever way the flag is set: presence here must
        // equal the flag's own value once earbudPaired is out of the
        // picture, and the earbudPaired tests above must hold regardless.
        let nonEarbud = CallCapabilities.localCaps(earbudActive: false, earbudPaired: false)
        XCTAssertEqual(CallCapabilities.audioSrtpSendEnabled, nonEarbud.contains(CallCapabilities.audioSrtpV1))
    }

    // MARK: - Negotiation

    func test_negotiated_useAudioSrtp_trueOnlyWhenBothSidesAgreedTheTag() {
        let bothAgree = CallCapabilities.negotiate(local: [CallCapabilities.audioSrtpV1], peer: [CallCapabilities.audioSrtpV1])
        XCTAssertTrue(bothAgree.useAudioSrtp)

        let onlyLocal = CallCapabilities.negotiate(local: [CallCapabilities.audioSrtpV1], peer: [])
        XCTAssertFalse(onlyLocal.useAudioSrtp)

        let onlyPeer = CallCapabilities.negotiate(local: [], peer: [CallCapabilities.audioSrtpV1])
        XCTAssertFalse(onlyPeer.useAudioSrtp)

        let neither = CallCapabilities.negotiate(local: [], peer: nil)
        XCTAssertFalse(neither.useAudioSrtp)
    }

    // MARK: - Tag string cross-platform contract

    func test_audioSrtpV1_matchesAndroidsByteExactWireString() {
        XCTAssertEqual(CallCapabilities.audioSrtpV1, "audio-srtp-v1")
    }
}
