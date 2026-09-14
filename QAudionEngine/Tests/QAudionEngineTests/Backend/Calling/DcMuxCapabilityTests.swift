import XCTest
@testable import QAudionEngine

/// W-DCMUX (2026-08-11) — the `dc-mux-v1` transport tag and the two DataChannel
/// wire literals.
///
/// None of this was pinned anywhere on ANY platform before this file: grepping
/// `DC_MUX_V1`, `dc-mux`, `DATA_CHANNEL_LABEL`, `qaudion-audio` and
/// `qaudion-sealed` across every Android and iOS test tree returned nothing. The
/// three things asserted here are the three things whose breakage is invisible
/// until a real cross-platform call is silent:
///
///   1. the kill switch's value really matches its own documented
///      preconditions (see ``CallCapabilities/dcMuxAdvertiseEnabled``), and
///      the tag's presence in the advertised list tracks the switch exactly
///      in either state;
///   2. the advertisement gates never strip the tag — it is a TRANSPORT
///      statement, orthogonal to the sovereign/earbud key-custody policy those
///      gates enforce;
///   3. the DataChannel label and subprotocol literals still equal the strings
///      Android and Desktop compare against.
///
/// Why (1) is not paranoia: advertising this tag makes an Android peer STOP
/// eagerly routing audio through the WS relay and prefer the DataChannel once
/// it opens. Desktop shipped the tag before its own DC path was reliable and
/// wrote the outcome down in `CallCapabilities.ts:76-83`: the two ends sat on
/// opposite transports and the call was silent. Advertising a path that is
/// not there does not degrade a call, it kills it. Android's own historical
/// version of that same failure — destroying the WS relay receive pump on a
/// DataChannel upgrade — is what `dcMuxAdvertiseEnabled`'s doc comment cites
/// as condition (b); as of `qaudion-android-new`'s current
/// `CallTransportFactory.kt` (`ResilientFrameRelayTransport`) that specific
/// failure mode is redesigned away, not merely avoided by luck: both receive
/// pumps live for the whole call regardless of which leg is transmitting.
///
/// No WebRTC import: every value tested is a pure constant or a pure function,
/// so this runs on a CI machine without the WebRTC binary.
final class DcMuxCapabilityTests: XCTestCase {

    // MARK: - 1. the kill switch, and what it gates

    /// 2026-08-25 — this test used to assert the switch ships OFF
    /// unconditionally. Like the original, it still asserts a fixed value —
    /// a unit test cannot itself re-derive "does production log evidence
    /// exist" or "does today's Android source have this design" — but the
    /// expected value flips to `true` because both preconditions the
    /// original assertion message named have now been checked against real
    /// evidence rather than assumed: (a) Phase 0 log evidence the
    /// DataChannel opens and carries frames on a real Android<->iOS call —
    /// call `532a3161` (2026-08-22 Loki correlation), dc=2717/ws=33; (b)
    /// "the Android WS-receive-fallback companion change" — verified
    /// present in `qaudion-android-new`'s `CallTransportFactory.kt`
    /// (`ResilientFrameRelayTransport`: WS and DC receive pumps both live
    /// for the whole call regardless of the active transmit leg) and pinned
    /// there by `ResilientTransportLegSymmetryTest.kt`. Full citation trail
    /// in `dcMuxAdvertiseEnabled`'s own doc comment. If a future change
    /// flips the flag back to `false`, that means one of the two conditions
    /// regressed — update this assertion AND investigate why, in that
    /// order, same as any other kill-switch state change in this file.
    func testDcMuxAdvertiseKillSwitchMatchesItsDocumentedPreconditions() {
        XCTAssertTrue(
            CallCapabilities.dcMuxAdvertiseEnabled,
            "dc-mux-v1 advertisement requires (a) Phase 0 evidence from logs "
            + "that the DataChannel opens and carries frames on a real "
            + "Android<->iOS call, and (b) the Android WS-receive-fallback "
            + "companion change. Both were verified with citations as of "
            + "2026-08-25 (see CallCapabilities.dcMuxAdvertiseEnabled's doc "
            + "comment) — if this now reads false, re-check whether (a) or "
            + "(b) actually regressed before assuming this assertion is "
            + "simply stale.")
    }

    func testLocalOmitsDcMuxWhileKillSwitchIsOff() {
        // Guarded on the flag so the test states the RULE, not today's value:
        // it keeps meaning the right thing after the flip instead of turning
        // into a red build that gets deleted.
        if CallCapabilities.dcMuxAdvertiseEnabled {
            XCTAssertTrue(CallCapabilities.local.contains(CallCapabilities.dcMuxV1))
        } else {
            XCTAssertFalse(
                CallCapabilities.local.contains(CallCapabilities.dcMuxV1),
                "the kill switch is off, so the tag must not be in the "
                + "advertised list — an unadvertised tag is the whole safety "
                + "mechanism")
        }
    }

    func testKillSwitchOffMeansEmptyIntersectionHoweverGenerousThePeerIs() {
        guard !CallCapabilities.dcMuxAdvertiseEnabled else { return }
        // An Android peer advertises dc-mux-v1 unconditionally
        // (CallCapabilities.kt:274). The intersection must still be empty,
        // which is exactly what makes Android take `peer-no-dc-mux` and keep
        // audio on the relay.
        let n = CallCapabilities.negotiate(
            local: CallCapabilities.localCaps(),
            peer: [CallCapabilities.sframeV1,
                   CallCapabilities.ratchetV3,
                   CallCapabilities.vkeyV1,
                   CallCapabilities.dcMuxV1])
        XCTAssertFalse(n.agreedTags.contains(CallCapabilities.dcMuxV1))
    }

    func testGateFunctionKeepsTheTagWhenTheBaseListCarriesIt() {
        // Fed an explicit base containing the tag, the gates must pass it
        // through. Testing `localCaps()` alone would pass vacuously today — the
        // tag is absent from `local` while the switch is off, so "kept" and
        // "never present" are indistinguishable, and the behaviour would stay
        // untested until the release that depends on it.
        let base = CallCapabilities.local + [CallCapabilities.dcMuxV1]
        let caps = CallCapabilities.applyAdvertisementGates(to: base)
        XCTAssertTrue(caps.contains(CallCapabilities.dcMuxV1))
    }

    // MARK: - 2. no gate may ever strip it

    func testNoAdvertisementGateCombinationStripsDcMux() {
        let base = CallCapabilities.local + [CallCapabilities.dcMuxV1]
        for sovereignOnly in [false, true] {
            for earbudActive in [false, true] {
                for earbudPaired in [nil, false, true] as [Bool?] {
                    let caps = CallCapabilities.applyAdvertisementGates(
                        to: base,
                        earbudActive: earbudActive,
                        sovereignOnly: sovereignOnly,
                        earbudPaired: earbudPaired)
                    XCTAssertTrue(
                        caps.contains(CallCapabilities.dcMuxV1),
                        "dc-mux-v1 stripped by sovereignOnly=\(sovereignOnly) "
                        + "earbudActive=\(earbudActive) earbudPaired=\(String(describing: earbudPaired)). "
                        + "It must not be: an earbud call relays these same "
                        + "sealed frames opaquely and the transport is "
                        + "orthogonal to who holds the key. Android never "
                        + "strips it either, and an asymmetric strip puts the "
                        + "two ends on different transports.")
                }
            }
        }
    }

    func testTheGatesStillStripWhatTheyAreSupposedToStrip() {
        // Counter-test: the loop above would also pass if `applyAdvertisementGates`
        // had quietly become the identity function.
        let base = CallCapabilities.local
            + [CallCapabilities.dcMuxV1, CallCapabilities.aprof60x256RecvV1]
        let sovereign = CallCapabilities.applyAdvertisementGates(
            to: base, sovereignOnly: true)
        XCTAssertFalse(sovereign.contains(CallCapabilities.vkeyV1))
        let earbud = CallCapabilities.applyAdvertisementGates(
            to: base, earbudActive: true)
        XCTAssertFalse(earbud.contains(CallCapabilities.aprof60x256RecvV1))
    }

    // MARK: - 3. the byte-exact strings

    func testCapabilityTagIsByteExact() {
        // Android CallCapabilities.kt:128, Desktop CallCapabilities.ts:85.
        // Compared with plain string equality on all three platforms.
        XCTAssertEqual(CallCapabilities.dcMuxV1, "dc-mux-v1")
    }

    func testDataChannelWireLiteralsAreByteExact() {
        // The label is LOAD-BEARING: Android selects the sealed-audio channel by
        // `label == "qaudion-audio"` (PeerConnectionHolder.kt:3865) and iOS does
        // the same in `didOpen`. A rename on one platform is a runtime-only
        // interop break — the build stays green and the call goes silent.
        XCTAssertEqual(SealedAudioDataChannelWire.label, "qaudion-audio")
        // The subprotocol is symmetry, not negotiation: neither end reads it.
        // iOS currently leaves the channel's subprotocol unset; the constant is
        // pinned so the agreed value stays written down and is copied rather
        // than retyped if it is ever set.
        XCTAssertEqual(SealedAudioDataChannelWire.subprotocol, "qaudion-sealed/1")
    }

    func testWireLiteralsCarryNoWhitespaceOrCasingDrift() {
        for s in [SealedAudioDataChannelWire.label,
                  SealedAudioDataChannelWire.subprotocol,
                  CallCapabilities.dcMuxV1] {
            XCTAssertEqual(s, s.trimmingCharacters(in: .whitespacesAndNewlines))
            XCTAssertEqual(s, s.lowercased())
            XCTAssertTrue(s.allSatisfy { $0.isASCII })
        }
    }
}
