import XCTest
@testable import QAudionEngine

/// W-LONGAUDIO (2026-08-10) — the negotiated 60 ms / 256-byte audio profile.
///
/// The twelve-row truth table from the implementation contract, plus the
/// invariants that keep the feature from reaching anything it must not touch.
/// Mirrors Kotlin `CallCapabilitiesTest` and the Desktop port row for row, so a
/// platform that drifts fails on the side that drifted.
///
/// The rows are stated in terms of what each side ADVERTISES, because that is
/// the only input either end actually has. `local` here is an explicit list
/// rather than `CallCapabilities.local`: the shipped build advertises neither
/// tag (both kill switches are `false`), and a test that could only run in a
/// build with them flipped would be a test that never runs.
final class LongAudioProfileNegotiationTests: XCTestCase {

    // Shorthand for the tags under test.
    private let recv = CallCapabilities.aprof60x256RecvV1
    private let send = CallCapabilities.aprof60x256V1
    /// A minimal realistic base so the rows are not testing an empty universe.
    private let base = [CallCapabilities.sframeV1, CallCapabilities.ratchetV3]

    private func negotiated(local: [String], peer: [String]?) -> CallCapabilities.Negotiated {
        CallCapabilities.negotiate(local: local, peer: peer)
    }

    // MARK: - The literals

    /// The tag strings are the entire interop contract. They are compared as
    /// plain strings on three platforms and inside no schema that would catch a
    /// typo, so they are pinned here as literals rather than as references —
    /// a test that says `XCTAssertEqual(x, x)` would pass through any rename.
    func test_tagLiterals_areByteExact() {
        XCTAssertEqual(CallCapabilities.aprof60x256RecvV1, "aprof-60x256-recv-v1")
        XCTAssertEqual(CallCapabilities.aprof60x256V1, "aprof-60x256-v1")
    }

    /// Both switches ship ON as of 2026-08-11, and they ship TOGETHER.
    ///
    /// They were `false` until then. The staged order the flags' own kdoc
    /// prescribed — receive first, alone, until a 60 ms frame is seen on iOS
    /// hardware — turned out to be unfollowable: Android sends a 60 ms frame
    /// only when the SEND tag is in the intersection, so a recv-only iOS build
    /// receives nothing to learn from. The pairing is asserted here rather than
    /// left to a comment, because a build that advertised receive without send
    /// would be inert and look deployed.
    func test_killSwitches_shipOnTogether() {
        XCTAssertTrue(CallCapabilities.longAudioSendEnabled,
                      "send is on since 2026-08-11 — see the flag's kdoc for the evidence")
        XCTAssertTrue(CallCapabilities.longAudioRecvAdvertiseEnabled,
                      "receive must be on whenever send is: the peer's resolver reads BOTH")
        XCTAssertEqual(CallCapabilities.longAudioSendEnabled,
                       CallCapabilities.longAudioRecvAdvertiseEnabled,
                       "the two switches are one decision on this platform; a build with send " +
                       "on and receive off advertises a profile it never invites, and one with " +
                       "receive on and send off changes nothing at all")
    }

    /// And therefore the shipped advertisement carries BOTH tags. A peer reads
    /// them separately — the send tag through the intersection, the receive tag
    /// out of our raw list — so neither may go missing.
    func test_shippedAdvertisement_carriesBothTags() {
        let caps = CallCapabilities.localCaps()
        XCTAssertTrue(caps.contains(recv))
        XCTAssertTrue(caps.contains(send))
        // ...and nothing else moved.
        XCTAssertTrue(caps.contains(CallCapabilities.sframeV1))
        XCTAssertTrue(caps.contains(CallCapabilities.ratchetV3))
        XCTAssertTrue(caps.contains(CallCapabilities.vkeyV1))
        XCTAssertTrue(caps.contains(CallCapabilities.upgradeIntentRecvV1))
    }

    // MARK: - The twelve rows

    /// Row 1 — neither side advertises anything. Both send standard.
    func test_row1_neitherAdvertises() {
        let n = negotiated(local: base, peer: base)
        XCTAssertEqual(CallCapabilities.resolveAudioProfile(negotiated: n, earbudInCall: false), .standard)
    }

    /// Row 2 — we advertise recv, peer advertises nothing.
    func test_row2_localRecvOnly_peerSilent() {
        let n = negotiated(local: base + [recv], peer: base)
        XCTAssertEqual(CallCapabilities.resolveAudioProfile(negotiated: n, earbudInCall: false), .standard)
    }

    /// Row 3 — we advertise nothing, peer advertises both. Our intersection is
    /// empty, and so is theirs, so neither side sends long.
    func test_row3_localSilent_peerFull() {
        let n = negotiated(local: base, peer: base + [recv, send])
        XCTAssertFalse(n.bothAdvertiseLongAudioSend)
        XCTAssertEqual(CallCapabilities.resolveAudioProfile(negotiated: n, earbudInCall: false), .standard)
    }

    /// Row 4 — both advertise recv only. Everyone can receive; nobody sends.
    func test_row4_bothRecvOnly() {
        let n = negotiated(local: base + [recv], peer: base + [recv])
        XCTAssertTrue(n.peerAcceptsLongAudio)
        XCTAssertFalse(n.bothAdvertiseLongAudioSend)
        XCTAssertEqual(CallCapabilities.resolveAudioProfile(negotiated: n, earbudInCall: false), .standard)
    }

    /// Row 5 — we advertise both, peer only recv. Peer never said it would send,
    /// so there is no agreement to send.
    func test_row5_localFull_peerRecvOnly() {
        let n = negotiated(local: base + [recv, send], peer: base + [recv])
        XCTAssertTrue(n.peerAcceptsLongAudio)
        XCTAssertFalse(n.bothAdvertiseLongAudioSend)
        XCTAssertEqual(CallCapabilities.resolveAudioProfile(negotiated: n, earbudInCall: false), .standard)
    }

    /// Row 6 — the mirror of row 5.
    func test_row6_localRecvOnly_peerFull() {
        let n = negotiated(local: base + [recv], peer: base + [recv, send])
        XCTAssertFalse(n.bothAdvertiseLongAudioSend)
        XCTAssertEqual(CallCapabilities.resolveAudioProfile(negotiated: n, earbudInCall: false), .standard)
    }

    /// Row 7 — THE row. Both advertise both. This is the only combination that
    /// activates, and it activates on both ends by construction: each computes
    /// the same intersection from the same two lists.
    ///
    /// Gated on the send kill switch, exactly as production is. With the switch
    /// off this asserts the resolver refuses; flipping the switch turns it into
    /// the positive assertion without editing the test.
    func test_row7_bothFull_isTheOnlyActivatingCombination() {
        let n = negotiated(local: base + [recv, send], peer: base + [recv, send])
        XCTAssertTrue(n.bothAdvertiseLongAudioSend, "the intersection must contain the send tag")
        XCTAssertTrue(n.peerAcceptsLongAudio, "the peer's raw list must contain the recv tag")
        let resolved = CallCapabilities.resolveAudioProfile(negotiated: n, earbudInCall: false)
        if CallCapabilities.longAudioSendEnabled {
            XCTAssertEqual(resolved, .long60x256)
        } else {
            XCTAssertEqual(resolved, .standard, "kill switch off must beat a perfect negotiation")
        }
    }

    /// Row 8 — the asymmetric strip. A relay removes our send tag from what the
    /// peer sees, so the two ends latch DIFFERENTLY.
    ///
    /// The signalling array is unauthenticated, so this is not hypothetical. It
    /// stays survivable only because receive is unconditional: our side would
    /// send long, the peer's side computes an empty intersection and sends
    /// standard, and both directions still carry audio because neither receiver
    /// consults what it latched.
    ///
    /// It is also not an I4 violation: each DIRECTION is independently constant
    /// for the life of the call, and the size still depends only on the profile,
    /// never on the content.
    func test_row8_asymmetricStrip_leavesEachDirectionIndependentlyConstant() {
        // Our view: the peer advertised everything, so we may send long.
        let ourView = negotiated(local: base + [recv, send], peer: base + [recv, send])
        XCTAssertTrue(ourView.bothAdvertiseLongAudioSend)
        // The peer's view: our send tag was stripped in flight.
        let peerView = negotiated(local: base + [recv, send], peer: base + [recv])
        XCTAssertFalse(peerView.bothAdvertiseLongAudioSend)
        XCTAssertEqual(CallCapabilities.resolveAudioProfile(negotiated: peerView, earbudInCall: false),
                       .standard,
                       "the stripped side must fall back, not fail")
    }

    /// Row 9 — kill switch off locally. The tag is never advertised, so the
    /// intersection cannot contain it however generous the peer is.
    ///
    /// Until 2026-08-11 this row read the switch-off case straight off
    /// ``CallCapabilities/localCaps()``, because that WAS the switch-off case.
    /// Both switches ship on now, so the list has to be built explicitly — the
    /// rule still needs testing even though this build can no longer produce
    /// the state it describes. A peer platform that has not flipped yet
    /// (Desktop today) is exactly this shape on the wire.
    func test_row9_killSwitchOff_neverAdvertises() {
        let switchOffLocal = CallCapabilities.localCaps().filter { $0 != send }
        let n = negotiated(local: switchOffLocal, peer: base + [recv, send])
        XCTAssertFalse(n.bothAdvertiseLongAudioSend)
        XCTAssertEqual(CallCapabilities.resolveAudioProfile(negotiated: n, earbudInCall: false), .standard)
    }

    /// The mirror of row 9 that only became reachable once the switches went
    /// on: OUR build advertises both tags, and the PEER is a platform that has
    /// not flipped yet. That is every iOS↔Desktop call today, so it is worth a
    /// row of its own rather than being implied by row 9.
    func test_row9b_peerHasNotFlipped_staysStandard() {
        let n = negotiated(local: CallCapabilities.localCaps(), peer: base + [recv])
        XCTAssertFalse(n.bothAdvertiseLongAudioSend)
        XCTAssertEqual(CallCapabilities.resolveAudioProfile(negotiated: n, earbudInCall: false), .standard)
    }

    /// And the case this build DOES produce against another flipped peer
    /// (Android since d3175700): both tags on both sides, so both send long.
    func test_row9c_bothFlipped_negotiatesLong() {
        let n = negotiated(local: CallCapabilities.localCaps(), peer: base + [recv, send])
        XCTAssertTrue(n.bothAdvertiseLongAudioSend)
        XCTAssertTrue(n.peerAcceptsLongAudio)
        XCTAssertEqual(CallCapabilities.resolveAudioProfile(negotiated: n, earbudInCall: false),
                       .long60x256)
    }

    /// Row 10 — a sovereign earbud is in the call. BOTH tags are withheld,
    /// including the receive one.
    ///
    /// Withholding recv is the part that looks over-cautious and is not: on an
    /// earbud call the phone relays the sealed frame without opening it, and the
    /// thing that decodes it is firmware with a 960-sample buffer that cannot do
    /// 60 ms at all. Advertising receive support on its behalf invites frames
    /// that arrive as silence and are reported nowhere.
    /// Driven through `applyAdvertisementGates` with an explicit base list that
    /// CONTAINS both tags. Testing `localCaps()` alone would pass vacuously
    /// today — the tags are absent from `local` while the kill switches are
    /// `false`, so "filtered out" and "never present" look identical, and the
    /// filter would stay untested until the release that depends on it.
    func test_row10_earbudPaired_withholdsBothTags() {
        let full = base + [recv, send]
        let caps = CallCapabilities.applyAdvertisementGates(to: full, earbudActive: true)
        XCTAssertFalse(caps.contains(recv), "the RECEIVE tag must be withheld too")
        XCTAssertFalse(caps.contains(send))
        XCTAssertTrue(caps.contains(CallCapabilities.earbudRelayV1))
        // Nothing unrelated was collaterally stripped.
        XCTAssertTrue(caps.contains(CallCapabilities.sframeV1))
        XCTAssertTrue(caps.contains(CallCapabilities.ratchetV3))
    }

    /// The gate keys on PAIRED, not ACTIVE: an earbud adopted after the
    /// advertisement went out would turn a true statement into a lie, and by
    /// then the peer has already latched.
    func test_row10_earbudPairedButNotActive_stillWithholdsBothTags() {
        let full = base + [recv, send]
        let caps = CallCapabilities.applyAdvertisementGates(
            to: full, earbudActive: false, earbudPaired: true)
        XCTAssertFalse(caps.contains(recv))
        XCTAssertFalse(caps.contains(send))
        // Not the active media path, so no relay tag.
        XCTAssertFalse(caps.contains(CallCapabilities.earbudRelayV1))
    }

    /// With no earbud, the gate is a pass-through for the audio tags — it must
    /// not be silently swallowing them in the normal case.
    func test_noEarbud_keepsBothTags() {
        let full = base + [recv, send]
        let caps = CallCapabilities.applyAdvertisementGates(to: full)
        XCTAssertTrue(caps.contains(recv))
        XCTAssertTrue(caps.contains(send))
        XCTAssertFalse(caps.contains(CallCapabilities.earbudRelayV1))
    }

    /// ...and the resolver refuses independently of the advertisement, so an
    /// earbud discovered late cannot leave us sending 60 ms into a 20 ms path.
    func test_row10_resolverRefusesWhenAnEarbudIsInTheCall() {
        let n = negotiated(local: base + [recv, send], peer: base + [recv, send])
        XCTAssertEqual(CallCapabilities.resolveAudioProfile(negotiated: n, earbudInCall: true),
                       .standard)
    }

    /// Row 11 — a malformed capability array (`[42, null]`).
    ///
    /// It never reaches `negotiate` as a partial list: the decode site casts the
    /// JSON to `[String]?` and a mixed array fails that cast WHOLE, yielding
    /// `nil`. Asserted here so nobody "improves" the cast into an element-wise
    /// one that would let half an array through.
    func test_row11_malformedPeerArray_decodesToNilAndFallsBack() {
        let wire: [String: Any] = ["capabilities": [42, NSNull()]]
        let decoded = wire["capabilities"] as? [String]
        XCTAssertNil(decoded, "a mixed-type array must fail the cast whole")
        let n = negotiated(local: base + [recv, send], peer: decoded)
        XCTAssertTrue(n.agreedTags.isEmpty)
        XCTAssertTrue(n.peerRawTags.isEmpty)
        XCTAssertEqual(CallCapabilities.resolveAudioProfile(negotiated: n, earbudInCall: false), .standard)
    }

    /// Row 12 — the negotiation result never arrives. The call runs standard for
    /// its whole life, which is the correct outcome and not a state to retry
    /// out of: a retry would be a mid-call switch wearing a different name.
    func test_row12_nilNegotiation_fallsBack() {
        XCTAssertEqual(CallCapabilities.resolveAudioProfile(negotiated: nil, earbudInCall: false),
                       .standard)
    }

    // MARK: - peerRawTags

    /// The raw list is carried through untouched. Without it the send gate
    /// cannot ask "can the peer RECEIVE this?", because the recv tag is only in
    /// the intersection when WE advertise it too.
    func test_peerRawTags_carriesTheUnintersectedList() {
        let n = negotiated(local: base, peer: base + [recv, "some-unknown-tag-v9"])
        XCTAssertTrue(n.peerRawTags.contains(recv))
        XCTAssertTrue(n.peerRawTags.contains("some-unknown-tag-v9"))
        XCTAssertFalse(n.agreedTags.contains(recv), "we did not advertise it, so it cannot be agreed")
        XCTAssertTrue(n.peerAcceptsLongAudio)
    }

    func test_peerRawTags_isEmptyForALegacyPeer() {
        XCTAssertTrue(negotiated(local: base, peer: nil).peerRawTags.isEmpty)
        XCTAssertFalse(negotiated(local: base, peer: nil).peerAcceptsLongAudio)
    }

    /// A peer that advertises SEND but not RECEIVE is not a peer we send to.
    /// The two tags mean different things and one does not imply the other;
    /// clause 4 of the activation rule exists for exactly this shape.
    func test_peerAdvertisingSendWithoutRecv_doesNotActivate() {
        let n = negotiated(local: base + [recv, send], peer: base + [send])
        XCTAssertTrue(n.bothAdvertiseLongAudioSend, "the intersection does contain the send tag")
        XCTAssertFalse(n.peerAcceptsLongAudio, "but the peer never claimed it can receive")
        XCTAssertEqual(CallCapabilities.resolveAudioProfile(negotiated: n, earbudInCall: false), .standard)
    }

    // MARK: - I5: the audio profile must not be able to move the video key

    /// Adding arbitrary tags to both sides' lists must not change the tag set
    /// that K_video is derived from.
    ///
    /// This is the proof that a string tag cannot black-screen video under the
    /// asymmetric-strip row. `ensureVideoSealerInternal` filters `agreedTags`
    /// down to the canonical three before hashing them into the HKDF `info`, so
    /// the projection is closed. The filter is reproduced here rather than
    /// invoked because it lives inside a closure on the WebRTC controller; if
    /// that filter is ever widened, this test keeps passing and the KAT
    /// (`PhoneVideoKeyKatTests`) is what fails — which is the right pair.
    func test_addingAudioTags_doesNotChangeTheVideoTranscriptProjection() {
        let canonical: (CallCapabilities.Negotiated) -> [String] = { n in
            n.agreedTags.filter {
                $0 == CallCapabilities.sframeV1
                    || $0 == CallCapabilities.ratchetV3
                    || $0 == CallCapabilities.vkeyV1
            }
        }
        let full = [CallCapabilities.sframeV1, CallCapabilities.ratchetV3, CallCapabilities.vkeyV1]
        let without = negotiated(local: full, peer: full)
        let with = negotiated(local: full + [recv, send], peer: full + [recv, send])
        XCTAssertEqual(canonical(without), canonical(with),
                       "an audio tag reached the video key derivation")
        XCTAssertEqual(canonical(with), full.sorted())
    }

    /// The same, for an arbitrary unknown tag — the general form of the
    /// invariant rather than the two tags this change happens to add.
    func test_addingAnyUnknownTag_doesNotChangeTheVideoTranscriptProjection() {
        let canonical: (CallCapabilities.Negotiated) -> [String] = { n in
            n.agreedTags.filter {
                $0 == CallCapabilities.sframeV1
                    || $0 == CallCapabilities.ratchetV3
                    || $0 == CallCapabilities.vkeyV1
            }
        }
        let full = [CallCapabilities.sframeV1, CallCapabilities.ratchetV3, CallCapabilities.vkeyV1]
        let with = negotiated(local: full + ["zzz-future-v1"], peer: full + ["zzz-future-v1"])
        XCTAssertEqual(canonical(with), full.sorted())
    }

    // MARK: - The gated accessor

    /// Sovereign-only still strips `vkey-v1`, and the audio tags are orthogonal
    /// to it — the two gates must compose rather than shadow one another.
    func test_sovereignOnly_stripsVkeyAndLeavesTheAudioGateAlone() {
        let caps = CallCapabilities.localCaps(sovereignOnly: true)
        XCTAssertFalse(caps.contains(CallCapabilities.vkeyV1))
        XCTAssertTrue(caps.contains(CallCapabilities.sframeV1))
    }

    // MARK: - §1.6 clause 2 — the list must belong to THIS call

    /// The whole point of the binding: a list captured for call A must not be
    /// visible to call B. This is the blocker case in its smallest form — the
    /// peer of the PREVIOUS call advertised both tags, the peer of THIS call
    /// advertised nothing, and without the id comparison the previous peer's
    /// list is what the latch would read.
    func test_capabilitiesCapturedForAnotherCall_areNotVisible() {
        let previousPeer = base + [recv, send]
        XCTAssertNil(CallCapabilities.peerCapabilities(
            forCallId: "22222222-2222-2222-2222-222222222222",
            capturedForCallId: "11111111-1111-1111-1111-111111111111",
            capturedList: previousPeer
        ))
    }

    /// …and the same list IS visible to the call it was captured for.
    func test_capabilitiesCapturedForThisCall_areVisible() {
        let peer = base + [recv, send]
        XCTAssertEqual(CallCapabilities.peerCapabilities(
            forCallId: "11111111-1111-1111-1111-111111111111",
            capturedForCallId: "11111111-1111-1111-1111-111111111111",
            capturedList: peer
        ), peer)
    }

    /// Case folding: an outgoing id is a lowercase UUID minted locally, an
    /// incoming one is whatever string the server sent. The SAME call must match
    /// through that difference — this file's `caseInsensitiveCompare` workarounds
    /// exist for exactly this.
    func test_theSameCallMatchesAcrossCaseDifferences() {
        let peer = base + [recv, send]
        XCTAssertEqual(CallCapabilities.peerCapabilities(
            forCallId: "ABCD1234-0000-0000-0000-000000000000",
            capturedForCallId: "abcd1234-0000-0000-0000-000000000000",
            capturedList: peer
        ), peer)
    }

    /// Nothing captured yet — the latch ran before the peer was heard from.
    /// Indistinguishable from "captured for another call" ON PURPOSE: both mean
    /// ownership cannot be proved, and the answer to that is STANDARD.
    func test_nothingCaptured_isNotVisible() {
        XCTAssertNil(CallCapabilities.peerCapabilities(
            forCallId: "11111111-1111-1111-1111-111111111111",
            capturedForCallId: nil,
            capturedList: base + [recv, send]
        ))
    }

    /// No active call id at the latch — the handshake beat the id binding.
    func test_noWantedCallId_isNotVisible() {
        XCTAssertNil(CallCapabilities.peerCapabilities(
            forCallId: nil,
            capturedForCallId: "11111111-1111-1111-1111-111111111111",
            capturedList: base + [recv, send]
        ))
    }

    /// Empty strings are not ids. A server that sent `"call_id": ""` must not
    /// produce a match against another empty id.
    func test_emptyIdsNeverMatch() {
        XCTAssertNil(CallCapabilities.peerCapabilities(
            forCallId: "",
            capturedForCallId: "",
            capturedList: base + [recv, send]
        ))
    }

    /// End to end through the resolver: the stale list from a modern peer,
    /// offered to a DIFFERENT call, must resolve to STANDARD. This is the
    /// blocker's failure sentence turned into an assertion — and it holds
    /// independently of the kill switch, which is what makes it meaningful
    /// before the switch is ever flipped.
    func test_staleCapabilities_resolveToStandard() {
        let stalePeer = base + [recv, send]
        let visible = CallCapabilities.peerCapabilities(
            forCallId: "22222222-2222-2222-2222-222222222222",
            capturedForCallId: "11111111-1111-1111-1111-111111111111",
            capturedList: stalePeer
        )
        let n = CallCapabilities.negotiate(local: base + [recv, send], peer: visible)
        XCTAssertFalse(n.bothAdvertiseLongAudioSend)
        XCTAssertFalse(n.peerAcceptsLongAudio)
        XCTAssertEqual(
            CallCapabilities.resolveAudioProfile(negotiated: n, earbudInCall: false),
            .standard
        )
    }
}
