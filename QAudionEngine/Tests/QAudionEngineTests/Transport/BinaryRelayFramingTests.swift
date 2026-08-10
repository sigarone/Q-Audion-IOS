import XCTest
import Foundation
import CryptoKit
@testable import QAudionEngine

/// BINARY WS RELAY FRAMING v1 — acceptance checks §6 (A1, A2, A3, B3, B4) plus
/// the cross-platform golden vector from §1.
///
/// The vectors here are the convergence point for iOS, Android, desktop and the
/// server: every implementer encodes the SAME frame with the SAME call id and
/// must produce the same 205 bytes. If one of these hashes changes, the wire
/// format changed and every other platform is now incompatible.
final class BinaryRelayFramingTests: XCTestCase {

    // MARK: - Golden vector (contract §1)

    /// FRAME187[i] = (i*7 + 13) & 0xFF, i in 0..<187.
    private static let frame187: Data = {
        var bytes = [UInt8]()
        bytes.reserveCapacity(187)
        for i in 0..<187 { bytes.append(UInt8((i &* 7 &+ 13) & 0xFF)) }
        return Data(bytes)
    }()

    private static let callId = "9f8e7d6c-5b4a-4938-8271-6f5e4d3c2b1a"

    private static let frame187Sha =
        "83e9d4736acaca0ce42e8f877b0540ef277770181835de0f669770e3e807a47c"
    private static let packetSha =
        "6a313a1c8d4ac97b93b73f91b190dc5f2fcb55dc8615bfbaa84f156439be3531"
    /// The base64 the text path puts in `frame` for the same golden frame —
    /// the one part of the 397-byte text uplink iOS fully controls (the rest is
    /// JSONSerialization's key order plus the envelope `id`).
    private static let frame187Base64 =
        "DRQbIikwNz5FTFNaYWhvdn2Ei5KZoKeutbzDytHY3+bt9PsCCRAXHiUsMzpBSE9WXWRrcnmAh46VnKOqsbi/xs3U2+Lp8Pf+BQwTGiEoLzY9REtSWWBnbnV8g4qRmJ+mrbS7wsnQ197l7PP6AQgPFh0kKzI5QEdOVVxjanF4f4aNlJuiqbC3vsXM09rh6O/2/QQLEhkgJy41PENKUVhfZm10e4KJkJeepayzusHIz9bd5Ovy+QAHDhUcIw=="

    private func sha256Hex(_ d: Data) -> String {
        SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
    }

    func testGoldenFrameFixtureMatchesContract() {
        XCTAssertEqual(Self.frame187.count, 187)
        XCTAssertEqual(sha256Hex(Self.frame187), Self.frame187Sha)
        XCTAssertEqual(Self.frame187.base64EncodedString(), Self.frame187Base64)
    }

    /// A1 — encode the golden frame with the golden call id.
    func testA1_encodeGoldenPacket() throws {
        let packet = try XCTUnwrap(
            BinaryRelayFraming.encodeAudio(callId: Self.callId, frame: Self.frame187))
        XCTAssertEqual(packet.count, 205)
        XCTAssertEqual(sha256Hex(packet), Self.packetSha)

        // Header, byte by byte.
        XCTAssertEqual(packet[0], 0xB1)
        XCTAssertEqual(packet[1], 0x11)
        XCTAssertEqual(
            Array(packet[2..<18]),
            [0x9f, 0x8e, 0x7d, 0x6c, 0x5b, 0x4a, 0x49, 0x38,
             0x82, 0x71, 0x6f, 0x5e, 0x4d, 0x3c, 0x2b, 0x1a])
        // The sealed frame is copied verbatim, offset 18 onward.
        XCTAssertEqual(packet.subdata(in: 18..<205), Self.frame187)
    }

    /// A2 — decode the §1 hex dump.
    func testA2_decodeGoldenPacket() throws {
        let packet = try XCTUnwrap(
            BinaryRelayFraming.encodeAudio(callId: Self.callId, frame: Self.frame187))
        let parsed = try XCTUnwrap(BinaryRelayFraming.parseAudio(packet))
        XCTAssertEqual(parsed.callId, Self.callId)
        XCTAssertEqual(sha256Hex(parsed.frame), Self.frame187Sha)
        XCTAssertEqual(parsed.frame, Self.frame187)
    }

    /// A2 — decode from raw literal bytes, independent of our own encoder, so
    /// an encoder bug cannot make this test pass with itself.
    func testA2_decodeFromLiteralBytes() throws {
        var raw = Data([0xB1, 0x11,
                        0x9f, 0x8e, 0x7d, 0x6c, 0x5b, 0x4a, 0x49, 0x38,
                        0x82, 0x71, 0x6f, 0x5e, 0x4d, 0x3c, 0x2b, 0x1a])
        raw.append(Self.frame187)
        XCTAssertEqual(raw.count, 205)
        XCTAssertEqual(sha256Hex(raw), Self.packetSha)

        let parsed = try XCTUnwrap(BinaryRelayFraming.parseAudio(raw))
        XCTAssertEqual(parsed.callId, "9f8e7d6c-5b4a-4938-8271-6f5e4d3c2b1a")
        XCTAssertEqual(sha256Hex(parsed.frame), Self.frame187Sha)
    }

    /// The parser must survive a `Data` slice whose `startIndex` is not zero —
    /// URLSession is free to hand us one, and absolute-offset subscripting of a
    /// slice is how that turns into wrong bytes or a trap.
    func testParserHandlesNonZeroBasedSlice() throws {
        var padded = Data([0xFF, 0xFF, 0xFF])
        let packet = try XCTUnwrap(
            BinaryRelayFraming.encodeAudio(callId: Self.callId, frame: Self.frame187))
        padded.append(packet)
        let slice = padded[3...]
        XCTAssertNotEqual(slice.startIndex, 0)

        let parsed = try XCTUnwrap(BinaryRelayFraming.parseAudio(slice))
        XCTAssertEqual(parsed.callId, Self.callId)
        XCTAssertEqual(parsed.frame, Self.frame187)
    }

    // MARK: - A3 corrupt-input battery

    func testA3_rejectsTooShort() {
        // Exactly the header and nothing else — a frame of zero bytes.
        let header = Data([0xB1, 0x11] + [UInt8](repeating: 0, count: 16))
        XCTAssertEqual(header.count, 18)
        XCTAssertNil(BinaryRelayFraming.parseAudio(header))
    }

    func testA3_rejectsEmpty() {
        XCTAssertNil(BinaryRelayFraming.parseAudio(Data()))
    }

    func testA3_rejectsWrongMagic() throws {
        var packet = try XCTUnwrap(
            BinaryRelayFraming.encodeAudio(callId: Self.callId, frame: Self.frame187))
        packet[0] = 0xB0
        XCTAssertNil(BinaryRelayFraming.parseAudio(packet))
    }

    func testA3_rejectsWrongHeaderVersion() throws {
        var packet = try XCTUnwrap(
            BinaryRelayFraming.encodeAudio(callId: Self.callId, frame: Self.frame187))
        packet[1] = 0x21   // version 2, kind audio — never reinterpret v1
        XCTAssertNil(BinaryRelayFraming.parseAudio(packet))
    }

    /// Video (kind 0x02) is FORBIDDEN in phase 1: `video_frame` carries
    /// `is_key_frame`, which is content-correlated.
    func testA3_rejectsVideoKind() throws {
        var packet = try XCTUnwrap(
            BinaryRelayFraming.encodeAudio(callId: Self.callId, frame: Self.frame187))
        packet[1] = 0x12
        XCTAssertNil(BinaryRelayFraming.parseAudio(packet))
        XCTAssertEqual(BinaryRelayFraming.kindVideoReserved, 0x2)
    }

    func testA3_rejectsOverReadLimit() {
        var packet = Data([0xB1, 0x11] + [UInt8](repeating: 0, count: 16))
        packet.append(Data(repeating: 0x5A, count: 32769 - 18))
        XCTAssertEqual(packet.count, 32769)
        XCTAssertNil(BinaryRelayFraming.parseAudio(packet))

        // …and exactly at the limit it is still accepted: the bound is the
        // server's existing SetReadLimit(32768), not a guess.
        let atLimit = packet.subdata(in: 0..<32768)
        XCTAssertNotNil(BinaryRelayFraming.parseAudio(atLimit))
    }

    /// An all-zero call id is a perfectly well-formed packet. Whether such a
    /// call exists is a routing question for the server, not a framing one —
    /// the parser must not invent a policy here.
    func testA3_allZeroCallIdParsesAsNilUuid() throws {
        var packet = Data([0xB1, 0x11] + [UInt8](repeating: 0, count: 16))
        packet.append(Self.frame187)
        let parsed = try XCTUnwrap(BinaryRelayFraming.parseAudio(packet))
        XCTAssertEqual(parsed.callId, "00000000-0000-0000-0000-000000000000")
        XCTAssertEqual(parsed.frame, Self.frame187)
    }

    func testEncodeRejectsUnparseableCallId() {
        for bad in ["", "not-a-uuid", "9f8e7d6c5b4a49388271 6f5e4d3c2b1a",
                    "9f8e7d6c-5b4a-4938-8271-6f5e4d3c2b1", "zzzzzzzz-5b4a-4938-8271-6f5e4d3c2b1a"] {
            XCTAssertNil(BinaryRelayFraming.encodeAudio(callId: bad, frame: Self.frame187),
                         "call id \(bad) must not encode")
        }
    }

    func testEncodeRejectsEmptyFrame() {
        XCTAssertNil(BinaryRelayFraming.encodeAudio(callId: Self.callId, frame: Data()))
    }

    /// Header shape: 18 bytes, and no header byte varies with the frame's
    /// contents or its length. Two frames of different lengths for the same
    /// call must produce byte-identical headers.
    func testHeaderCarriesNothingDerivedFromTheFrame() throws {
        let short = try XCTUnwrap(
            BinaryRelayFraming.encodeAudio(callId: Self.callId, frame: Data(repeating: 0x01, count: 187)))
        let long = try XCTUnwrap(
            BinaryRelayFraming.encodeAudio(callId: Self.callId, frame: Data(repeating: 0xFE, count: 323)))
        XCTAssertEqual(short.prefix(18), long.prefix(18))
        XCTAssertEqual(BinaryRelayFraming.headerLength, 18)

        // Different call, same frame → the ONLY difference is the call id.
        let otherCall = try XCTUnwrap(
            BinaryRelayFraming.encodeAudio(callId: "1b2c3d4e-5f60-4718-9a2b-3c4d5e6f7a8b",
                                           frame: Data(repeating: 0x01, count: 187)))
        XCTAssertEqual(short.prefix(2), otherCall.prefix(2))
        XCTAssertNotEqual(short.prefix(18), otherCall.prefix(18))
        XCTAssertEqual(short.suffix(from: 18), otherCall.suffix(from: 18))
    }

    /// Constant rate: every packet of a given call is the same size, whatever
    /// the frame content.
    func testConstantPacketSizeForAGivenProfile() throws {
        var sizes = Set<Int>()
        for seed in 0..<32 {
            let frame = Data((0..<187).map { UInt8(($0 &* 31 &+ seed) & 0xFF) })
            let packet = try XCTUnwrap(
                BinaryRelayFraming.encodeAudio(callId: Self.callId, frame: frame))
            sizes.insert(packet.count)
        }
        XCTAssertEqual(sizes, [205])
    }

    func testUuidByteOrderIsCanonicalPrintedOrder() throws {
        let bytes = try XCTUnwrap(BinaryRelayFraming.uuidBytes(Self.callId))
        XCTAssertEqual(bytes.first, 0x9f)
        XCTAssertEqual(bytes.last, 0x1a)
        XCTAssertEqual(BinaryRelayFraming.canonicalUuidString(bytes), Self.callId)
        // Uppercase input, lowercase canonical output — so an id that arrives
        // over binary compares equal to the same id that arrived over text.
        let upper = try XCTUnwrap(BinaryRelayFraming.uuidBytes(Self.callId.uppercased()))
        XCTAssertEqual(bytes, upper)
    }

    // MARK: - B3: default OFF, and only the echo can turn it on

    func testB3_shippedKillSwitchesAreOff() {
        XCTAssertFalse(CallCapabilities.binRelayReceiveEnabled,
                       "binary relay must ship OFF — flipping this is a deliberate release step")
        XCTAssertFalse(CallCapabilities.binRelaySendEnabled,
                       "binary send must ship OFF — see the rollout order in the contract §7")
    }

    /// Framing is hop-by-hop, so it must never appear in the end-to-end
    /// capability array the server is required to stay blind to.
    func testB3_framingIsNotACapabilityTag() {
        for cap in CallCapabilities.local {
            XCTAssertFalse(cap.contains("bin"), "unexpected framing-ish capability tag: \(cap)")
            XCTAssertFalse(cap.contains("relay-bin"), "unexpected framing tag: \(cap)")
        }
    }

    func testB3_flagIsFalseAfterConstructionAndAfterDisconnect() {
        let client = BCryptoWebSocketClient(
            config: BackendConfig(serverUrl: "https://example.invalid"))
        XCTAssertFalse(client.binRelayNegotiated)
        client.disconnect()
        XCTAssertFalse(client.binRelayNegotiated)
        XCTAssertEqual(client.binaryFramesReceived, 0)
    }

    /// The latch rule, in full: the ONLY value that grants binary is a literal
    /// integer 1. Everything else — absent, boolean, string, 0, 2, null — means
    /// text forever on that socket.
    func testB3_onlyIntegerOneGrantsBinary() {
        XCTAssertTrue(BCryptoWebSocketClient.isBinRelayGrant(NSNumber(value: 1)))
        XCTAssertTrue(BCryptoWebSocketClient.isBinRelayGrant(1))

        XCTAssertFalse(BCryptoWebSocketClient.isBinRelayGrant(nil))
        XCTAssertFalse(BCryptoWebSocketClient.isBinRelayGrant(NSNull()))
        XCTAssertFalse(BCryptoWebSocketClient.isBinRelayGrant(0))
        XCTAssertFalse(BCryptoWebSocketClient.isBinRelayGrant(2))
        XCTAssertFalse(BCryptoWebSocketClient.isBinRelayGrant(-1))
        XCTAssertFalse(BCryptoWebSocketClient.isBinRelayGrant(1.5))
        XCTAssertFalse(BCryptoWebSocketClient.isBinRelayGrant("1"))
        XCTAssertFalse(BCryptoWebSocketClient.isBinRelayGrant([1]))
        // Drive the exact shape JSONSerialization produces for an
        // `authenticated` payload, not a hand-built NSNumber: JSON `true`
        // bridges to an NSNumber whose intValue is 1, and that must NOT be a
        // grant.
        func binRelayValue(_ json: String) -> Any? {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)),
                  let dict = obj as? [String: Any] else { return nil }
            return dict["bin_relay"]
        }
        XCTAssertTrue(BCryptoWebSocketClient.isBinRelayGrant(binRelayValue(#"{"bin_relay":1}"#)))
        XCTAssertFalse(BCryptoWebSocketClient.isBinRelayGrant(binRelayValue(#"{"bin_relay":true}"#)))
        XCTAssertFalse(BCryptoWebSocketClient.isBinRelayGrant(binRelayValue(#"{"bin_relay":"1"}"#)))
        XCTAssertFalse(BCryptoWebSocketClient.isBinRelayGrant(binRelayValue(#"{"bin_relay":0}"#)))
        XCTAssertFalse(BCryptoWebSocketClient.isBinRelayGrant(binRelayValue(#"{"bin_relay":2}"#)))
        XCTAssertFalse(BCryptoWebSocketClient.isBinRelayGrant(binRelayValue(#"{}"#)))
    }

    // MARK: - Wire-form latch (B4 and the never-upgrade rule)

    func testLatchStaysTextWhileSendSwitchIsOff() {
        let latch = BinaryRelayWireFormLatch()
        XCTAssertEqual(
            latch.resolve(callId: Self.callId, socketNegotiated: true, sendEnabled: false),
            .text)
        // Nothing was even tracked: with the switch off this is a pure function.
        XCTAssertEqual(latch.trackedCallCount, 0)
    }

    func testLatchIsBinaryOnlyWhenTheSocketWasGranted() {
        let latch = BinaryRelayWireFormLatch()
        XCTAssertEqual(
            latch.resolve(callId: Self.callId, socketNegotiated: true, sendEnabled: true),
            .binary)

        let other = BinaryRelayWireFormLatch()
        XCTAssertEqual(
            other.resolve(callId: Self.callId, socketNegotiated: false, sendEnabled: true),
            .text)
    }

    /// B4 — socket dies mid-call, reconnects without the echo: the call goes to
    /// text for the REST of the call, and never returns to binary. Both halves.
    func testB4_downgradeOnceIsTerminal() {
        let latch = BinaryRelayWireFormLatch()
        XCTAssertEqual(
            latch.resolve(callId: Self.callId, socketNegotiated: true, sendEnabled: true),
            .binary)
        // Socket dropped; the replacement did not get the echo.
        XCTAssertEqual(
            latch.resolve(callId: Self.callId, socketNegotiated: false, sendEnabled: true),
            .text)
        // A later socket DOES get the echo — the call must stay on text anyway.
        for _ in 0..<10 {
            XCTAssertEqual(
                latch.resolve(callId: Self.callId, socketNegotiated: true, sendEnabled: true),
                .text)
        }
        XCTAssertEqual(latch.peek(callId: Self.callId), .text)
    }

    /// Never upgrade mid-call, even when the call started on text simply
    /// because the first frame raced the `authenticated` echo.
    func testLatchNeverUpgradesMidCall() {
        let latch = BinaryRelayWireFormLatch()
        XCTAssertEqual(
            latch.resolve(callId: Self.callId, socketNegotiated: false, sendEnabled: true),
            .text)
        XCTAssertEqual(
            latch.resolve(callId: Self.callId, socketNegotiated: true, sendEnabled: true),
            .text)
    }

    /// A NEW call on a granted socket resolves independently of an older call
    /// that was downgraded — the latch is per call, not global.
    func testLatchIsPerCall() {
        let latch = BinaryRelayWireFormLatch()
        let callA = Self.callId
        let callB = "1b2c3d4e-5f60-4718-9a2b-3c4d5e6f7a8b"
        XCTAssertEqual(latch.resolve(callId: callA, socketNegotiated: true, sendEnabled: true), .binary)
        XCTAssertEqual(latch.resolve(callId: callA, socketNegotiated: false, sendEnabled: true), .text)
        XCTAssertEqual(latch.resolve(callId: callB, socketNegotiated: true, sendEnabled: true), .binary)
        XCTAssertEqual(latch.peek(callId: callA), .text)
        XCTAssertEqual(latch.peek(callId: callB), .binary)
    }

    /// §2.4 — a call id that does not parse to 16 bytes runs on text, silently,
    /// and is not tracked (so it can never be promised a form the encoder would
    /// then refuse).
    func testLatchKeepsUnparseableCallIdsOnText() {
        let latch = BinaryRelayWireFormLatch()
        XCTAssertEqual(latch.resolve(callId: nil, socketNegotiated: true, sendEnabled: true), .text)
        XCTAssertEqual(latch.resolve(callId: "", socketNegotiated: true, sendEnabled: true), .text)
        XCTAssertEqual(latch.resolve(callId: "room-42", socketNegotiated: true, sendEnabled: true), .text)
        XCTAssertEqual(latch.trackedCallCount, 0)
    }

    /// The latch KEYS case-insensitively — one call is one entry however it is
    /// spelled — but it does not RESOLVE an uppercase id to binary. Those are
    /// two different properties and only the first one was ever wanted.
    ///
    /// The previous version of this test asserted `uppercased() -> .binary`,
    /// which pinned the exact defect the four-way byte-parity comparison found:
    /// the server's binary path lowercases the id it decodes
    /// (`binary_relay.go:303` via `id.String()`) and then looks it up in a call
    /// table keyed on the RAW wire string (`lite_hub.go:377`), so an
    /// iOS-originated call — `UUID().uuidString` is uppercase — misses the
    /// table, fails `partyOK`, and its binary uplink is dropped with
    /// `call_relay_reject` while the same frame relays fine as text. This
    /// assertion is tightened, not relaxed: the id that used to be promised
    /// binary is now refused it.
    func testLatchKeysCaseInsensitivelyButRefusesNonCanonicalIds() {
        let latch = BinaryRelayWireFormLatch()
        // Uppercase: a real id the server's binary path cannot route. Text.
        XCTAssertEqual(
            latch.resolve(callId: Self.callId.uppercased(), socketNegotiated: true, sendEnabled: true),
            .text)
        // …and it is the SAME entry as the lowercase spelling, not a second one.
        XCTAssertEqual(latch.trackedCallCount, 1)
        XCTAssertEqual(latch.peek(callId: Self.callId), .text)
        XCTAssertEqual(latch.peek(callId: Self.callId.uppercased()), .text)
    }

    /// Case-insensitive keying, shown on the path that matters: a call latched
    /// (and then downgraded) under one spelling must stay downgraded under the
    /// other.
    func testLatchDowngradeAppliesToEitherSpelling() {
        let latch = BinaryRelayWireFormLatch()
        XCTAssertEqual(
            latch.resolve(callId: Self.callId, socketNegotiated: true, sendEnabled: true),
            .binary)
        XCTAssertEqual(
            latch.resolve(callId: Self.callId.uppercased(), socketNegotiated: false, sendEnabled: true),
            .text)
        XCTAssertEqual(
            latch.resolve(callId: Self.callId, socketNegotiated: true, sendEnabled: true),
            .text)
    }

    /// The client's encoder must refuse exactly what the SERVER's encoder
    /// refuses (`binary_relay.go:150`, `id.String() != callID`). Anything less
    /// strict produces a packet the server decodes fine and then cannot route,
    /// i.e. a silently dead uplink.
    func testEncodeRefusesNonCanonicalCallId() {
        XCTAssertNil(
            BinaryRelayFraming.encodeAudio(callId: Self.callId.uppercased(), frame: Self.frame187),
            "an uppercase call id must not encode — the server's table lookup would miss")
        XCTAssertNotNil(
            BinaryRelayFraming.encodeAudio(callId: Self.callId, frame: Self.frame187))
        XCTAssertTrue(BinaryRelayFraming.isServerCanonicalCallId(Self.callId))
        XCTAssertFalse(BinaryRelayFraming.isServerCanonicalCallId(Self.callId.uppercased()))
        XCTAssertFalse(BinaryRelayFraming.isServerCanonicalCallId("not-a-uuid"))
        // Foundation's own minting is uppercase — this is why the check exists
        // rather than being a theoretical hardening.
        XCTAssertFalse(BinaryRelayFraming.isServerCanonicalCallId(UUID().uuidString))
        XCTAssertTrue(BinaryRelayFraming.isServerCanonicalCallId(UUID().uuidString.lowercased()))
    }

    /// Eviction must prefer entries that were never downgraded: losing a
    /// downgraded entry is the one way a later frame could re-resolve to binary
    /// and produce the forbidden mid-call upgrade.
    func testLatchEvictionKeepsDowngradedEntries() {
        let latch = BinaryRelayWireFormLatch()
        let downgraded = Self.callId
        XCTAssertEqual(latch.resolve(callId: downgraded, socketNegotiated: true, sendEnabled: true), .binary)
        XCTAssertEqual(latch.resolve(callId: downgraded, socketNegotiated: false, sendEnabled: true), .text)

        for _ in 0..<(BinaryRelayWireFormLatch.maxTrackedCalls * 2) {
            _ = latch.resolve(callId: UUID().uuidString, socketNegotiated: true, sendEnabled: true)
        }
        XCTAssertLessThanOrEqual(latch.trackedCallCount, BinaryRelayWireFormLatch.maxTrackedCalls)
        XCTAssertEqual(latch.peek(callId: downgraded), .text,
                       "a downgraded call must not be evicted back into an upgrade")
    }

    /// Eviction must never pick the entry being inserted. Saturate the map with
    /// `.text` entries so the incoming `.binary` one is the ONLY binary entry:
    /// with the old append-then-search order the victim search found the key it
    /// had just appended, so that call was never latched at all and re-resolved
    /// on every frame.
    func testLatchEvictionNeverEvictsTheEntryBeingInserted() {
        let latch = BinaryRelayWireFormLatch()
        // Fill to capacity with entries that are all on text.
        for _ in 0..<BinaryRelayWireFormLatch.maxTrackedCalls {
            _ = latch.resolve(callId: UUID().uuidString.lowercased(),
                              socketNegotiated: false, sendEnabled: true)
        }
        XCTAssertEqual(latch.trackedCallCount, BinaryRelayWireFormLatch.maxTrackedCalls)

        let fresh = UUID().uuidString.lowercased()
        XCTAssertEqual(
            latch.resolve(callId: fresh, socketNegotiated: true, sendEnabled: true),
            .binary)
        XCTAssertEqual(latch.peek(callId: fresh), .binary,
                       "the new entry must survive its own insertion")
        XCTAssertLessThanOrEqual(latch.trackedCallCount,
                                 BinaryRelayWireFormLatch.maxTrackedCalls)
    }

    func testLatchForgetAndReset() {
        let latch = BinaryRelayWireFormLatch()
        _ = latch.resolve(callId: Self.callId, socketNegotiated: true, sendEnabled: true)
        latch.forget(callId: Self.callId)
        XCTAssertNil(latch.peek(callId: Self.callId))
        _ = latch.resolve(callId: Self.callId, socketNegotiated: true, sendEnabled: true)
        latch.reset()
        XCTAssertEqual(latch.trackedCallCount, 0)
    }

    // MARK: - Liveness fallback (the missing safety net)

    /// The one precondition the whole feature rests on — that a binary
    /// WebSocket frame survives Cloudflare + Caddy + the tunnel — has never
    /// been demonstrated and cannot be until the server speaks binary. These
    /// bounds are what makes that acceptable.
    ///
    /// The window is DERIVED, not chosen, and its FIRST term is the server's
    /// own veto window: the server's fallback repairs both legs of the socket
    /// (it stops sending binary and stops expecting a binary uplink), so it
    /// must always get the first move. A client window shorter than the
    /// server's pre-empts the better repair — which is exactly what the old
    /// 1800 ms constant did.
    ///
    /// The second term is the client's own floor: three times
    /// `PlayoutJitterBuffer.capacityMs`, the hard cap on how much audio the
    /// receiver can hold. One buffer-length of nothing arriving is the most the
    /// playout path can hide; three is unambiguously not jitter — the relay
    /// path's own jitter target is `AudioConstants.jitterBufferMsWsRelay`
    /// (160 ms), so that margin alone is over 11× the delay variation the path
    /// is designed for.
    func testLivenessWindowGivesTheServerTheFirstMove() {
        let windowMs = BCryptoWebSocketClient.binRelayLivenessWindowMs
        let serverMs = BCryptoWebSocketClient.binRelayServerVetoWindowMs
        // cmd/bcrypto-lite/binary_relay.go: binRelayLivenessWindow = 3s.
        XCTAssertEqual(serverMs, 3000)
        XCTAssertEqual(windowMs, serverMs + PlayoutJitterBuffer.capacityMs * 3)
        XCTAssertGreaterThan(windowMs, serverMs,
                             "the server's bidirectional veto must land first")
        XCTAssertGreaterThanOrEqual(windowMs - serverMs, PlayoutJitterBuffer.capacityMs * 3,
                                    "and by a margin, not by a hair")
        XCTAssertGreaterThan(windowMs, PlayoutJitterBuffer.capacityMs,
                             "must exceed everything the playout buffer can absorb")
        XCTAssertGreaterThan(windowMs, AudioConstants.jitterBufferMsWsRelay * 4,
                             "must not trip on ordinary relay-path jitter")
        // It is now ABOVE mediaKickWindowSec, which the old constant sat below.
        // That is deliberate and safe: the media kick fires only on a socket
        // `send()` already considers stale — no inbound frame of ANY type for
        // pingIntervalSec * 2 (40 s) — and a socket that is merely missing
        // audio still answers pings. Pinned so the relation is a decision on
        // record rather than an accident.
        XCTAssertGreaterThan(Double(windowMs) / 1000.0,
                             BCryptoWebSocketClient.mediaKickWindowSec)
    }

    /// The window means nothing unless we were actually transmitting into it.
    /// The threshold is half of what the LONGEST supported frame duration
    /// yields across the window, so a sender on the 20 ms or the 60 ms profile
    /// clears it and a silent client never does.
    func testLivenessMinimumOutboundFramesIsReachableOnBothProfiles() {
        let windowMs = BCryptoWebSocketClient.binRelayLivenessWindowMs
        let minFrames = BCryptoWebSocketClient.binRelayLivenessMinOutboundFrames
        XCTAssertGreaterThan(minFrames, 0)
        // Frames a continuously-transmitting sender produces inside the window.
        let atShortProfile = windowMs / AudioConstants.frameDurationMs        // 20 ms
        let atLongProfile = windowMs / AudioConstants.maxFrameDurationMs      // 60 ms
        XCTAssertGreaterThan(atShortProfile, minFrames)
        XCTAssertGreaterThan(atLongProfile, minFrames)
    }

    /// The hold across the `authenticated` echo race is bounded two ways, and
    /// its age bound is the deepest the playout buffer will ever let itself
    /// get: a packet older than that would be dropped downstream anyway.
    func testEchoRaceHoldIsBounded() {
        XCTAssertEqual(BCryptoWebSocketClient.binRelayPendingHoldMs,
                       PlayoutJitterBuffer.emergencyWatermarkMs)
        XCTAssertGreaterThan(BCryptoWebSocketClient.binRelayPendingMaxFrames, 0)
        XCTAssertLessThan(BCryptoWebSocketClient.binRelayPendingMaxFrames, 64,
                          "this covers a two-channel write race, not an outage")
    }

    /// The downgrade signal has ONE spelling in both directions: the integer
    /// field `bin_relay`, value 0. Client→server it is the downgrade report
    /// (parsed at cmd/bcrypto-lite/main.go:6294 on `audio_frame` and :6123 on
    /// `authenticate`); server→client it is the veto. Same strictness as the
    /// grant: only a literal integer 0 counts, so a boolean `false`, a string
    /// `"0"` or an absent key can never silently downgrade a healthy call.
    func testOnlyIntegerZeroIsAVeto() {
        XCTAssertTrue(BCryptoWebSocketClient.isBinRelayVeto(NSNumber(value: 0)))
        XCTAssertTrue(BCryptoWebSocketClient.isBinRelayVeto(0))

        XCTAssertFalse(BCryptoWebSocketClient.isBinRelayVeto(nil))
        XCTAssertFalse(BCryptoWebSocketClient.isBinRelayVeto(NSNull()))
        XCTAssertFalse(BCryptoWebSocketClient.isBinRelayVeto(1))
        XCTAssertFalse(BCryptoWebSocketClient.isBinRelayVeto(-1))
        XCTAssertFalse(BCryptoWebSocketClient.isBinRelayVeto(0.5))
        XCTAssertFalse(BCryptoWebSocketClient.isBinRelayVeto("0"))
        XCTAssertFalse(BCryptoWebSocketClient.isBinRelayVeto([0]))
        // The shape JSONSerialization actually produces, not a hand-built
        // NSNumber: JSON `false` bridges to an NSNumber whose intValue is 0.
        func binRelayValue(_ json: String) -> Any? {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)),
                  let dict = obj as? [String: Any] else { return nil }
            return dict["bin_relay"]
        }
        XCTAssertTrue(BCryptoWebSocketClient.isBinRelayVeto(binRelayValue(#"{"bin_relay":0}"#)))
        XCTAssertFalse(BCryptoWebSocketClient.isBinRelayVeto(binRelayValue(#"{"bin_relay":false}"#)))
        XCTAssertFalse(BCryptoWebSocketClient.isBinRelayVeto(binRelayValue(#"{"bin_relay":"0"}"#)))
        XCTAssertFalse(BCryptoWebSocketClient.isBinRelayVeto(binRelayValue(#"{"bin_relay":1}"#)))
        XCTAssertFalse(BCryptoWebSocketClient.isBinRelayVeto(binRelayValue(#"{}"#)))
        // Grant and veto are mutually exclusive on every possible input shape.
        for raw in [0, 1, 2, -1] as [Any] {
            XCTAssertFalse(
                BCryptoWebSocketClient.isBinRelayGrant(raw)
                && BCryptoWebSocketClient.isBinRelayVeto(raw))
        }
    }

    // MARK: - D6: the affirmative ack

    /// A socket that has seen nothing owes nothing. The `bin_relay` key is
    /// ABSENT from an ordinary `audio_frame` — not present-and-zero, which the
    /// server would read as a downgrade report (`BinRelay *int`,
    /// cmd/bcrypto-lite/main.go:6323 — absent ≠ zero).
    func testAckIsNotOwedOnAFreshSocket() {
        let client = BCryptoWebSocketClient(
            config: BackendConfig(serverUrl: "https://example.invalid"))
        XCTAssertFalse(client.binRelayAckPending)
        XCTAssertFalse(client.binRelayAckSent)
        XCTAssertNil(client.takeBinRelayNoticeForOutboundFrame())
    }

    /// The whole point of D6: one binary frame in, one `bin_relay: 1` out, and
    /// then silence. Once per SOCKET, not once per frame — the server needs the
    /// fact stated, and restating it on a constant-rate stream would put a
    /// variable-size field on every frame for no added information.
    func testAckRidesExactlyOneFrameAndOnlyOnce() {
        let client = BCryptoWebSocketClient(
            config: BackendConfig(serverUrl: "https://example.invalid"))
        // First binary packet parsed on this socket.
        client.noteInboundBinaryFrameForAck()
        XCTAssertTrue(client.binRelayAckPending)
        XCTAssertFalse(client.binRelayAckSent, "not sent until a frame carries it")

        XCTAssertEqual(client.takeBinRelayNoticeForOutboundFrame(), 1)
        XCTAssertFalse(client.binRelayAckPending)
        XCTAssertTrue(client.binRelayAckSent)

        // Every later frame of this socket carries no key at all, including
        // after more binary arrives — the arming is latched, not re-armed.
        for _ in 0..<8 {
            client.noteInboundBinaryFrameForAck()
            XCTAssertNil(client.takeBinRelayNoticeForOutboundFrame())
        }
        XCTAssertFalse(client.binRelayAckPending)
    }

    /// Many binary frames before the first outbound text frame still produce
    /// ONE ack, not a queue of them.
    func testRepeatedArmingCollapsesToASingleAck() {
        let client = BCryptoWebSocketClient(
            config: BackendConfig(serverUrl: "https://example.invalid"))
        for _ in 0..<50 { client.noteInboundBinaryFrameForAck() }
        XCTAssertEqual(client.takeBinRelayNoticeForOutboundFrame(), 1)
        XCTAssertNil(client.takeBinRelayNoticeForOutboundFrame())
    }

    /// PRECEDENCE. Both notices can be owed at once — a socket receives binary
    /// (arming the ack), then goes deaf and trips the liveness watch before the
    /// ack has found a text frame to ride. In that order the ack is stale: the
    /// client is already back on text and the server must stop writing binary
    /// to it. `0` wins, on the one frame that had to carry the repair.
    ///
    /// Pinned as a pure function so the rule is checked without a socket, a
    /// server or a live trip.
    func testDowngradeReportBeatsAPendingAck() {
        XCTAssertNil(BCryptoWebSocketClient.binRelayNotice(
            owesDowngrade: false, owesAck: false))
        XCTAssertEqual(BCryptoWebSocketClient.binRelayNotice(
            owesDowngrade: false, owesAck: true), 1)
        XCTAssertEqual(BCryptoWebSocketClient.binRelayNotice(
            owesDowngrade: true, owesAck: false), 0)
        XCTAssertEqual(BCryptoWebSocketClient.binRelayNotice(
            owesDowngrade: true, owesAck: true), 0,
            "a stale ack must never override the downgrade that repairs the socket")
    }

    /// The ack is a statement about traffic that already arrived. It must not
    /// be readable as a grant: the ONLY input that may put a socket on binary
    /// is its own `authenticated` payload, and this value travels the other way
    /// on a different message type.
    func testAckNeverGrantsAnythingLocally() {
        let client = BCryptoWebSocketClient(
            config: BackendConfig(serverUrl: "https://example.invalid"))
        client.noteInboundBinaryFrameForAck()
        XCTAssertEqual(client.takeBinRelayNoticeForOutboundFrame(), 1)
        XCTAssertFalse(client.binRelayNegotiated,
                       "sending the ack must not latch this socket to binary")
        XCTAssertFalse(client.binRelayFallbackTripped)
    }

    /// A fresh client has not fallen back, and `disconnect()` does not fake it.
    /// The latch is per socket: only a new `connect()` clears it, and nothing
    /// in configuration can set it.
    func testFallbackLatchStartsClear() {
        let client = BCryptoWebSocketClient(
            config: BackendConfig(serverUrl: "https://example.invalid"))
        XCTAssertFalse(client.binRelayFallbackTripped)
        client.disconnect()
        XCTAssertFalse(client.binRelayFallbackTripped)
    }

    // MARK: - Content blindness

    /// The binary header must carry strictly LESS than the JSON envelope did.
    /// Mirrors the server's `TestBuildAudioRelayShape` forbidden-substring list:
    /// nothing in this format may describe the plaintext.
    func testHeaderExposesNoPlaintextDescriptor() throws {
        let packet = try XCTUnwrap(
            BinaryRelayFraming.encodeAudio(callId: Self.callId, frame: Self.frame187))
        // 18 header bytes = 1 magic + 1 ver_kind + 16 call id. Every byte is
        // accounted for, so there is no room for a length, a counter, a flag,
        // a sender id or a timestamp.
        XCTAssertEqual(BinaryRelayFraming.headerLength, 1 + 1 + 16)
        XCTAssertEqual(packet.count, BinaryRelayFraming.headerLength + Self.frame187.count)

        let parsed = try XCTUnwrap(BinaryRelayFraming.parseAudio(packet))
        // The parsed result carries only the two fields the JSON relay carried.
        XCTAssertEqual(parsed, BinaryRelayFraming.Parsed(callId: Self.callId, frame: Self.frame187))
    }
}
