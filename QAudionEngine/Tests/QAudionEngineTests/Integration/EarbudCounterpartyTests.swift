import XCTest
@testable import QAudionEngine

/// Port of Android `EarbudHandshakeResponderTest` (state machine / codec
/// behaviour) + `EarbudHandshakeCounterpartyKatTest` (CRUX KAT pinning):
/// proves the iOS counterparty path is byte-compatible with the Android
/// SW counterparty AND the earbud firmware, and that the crypto seam
/// stays on the frozen hybrid-combine-kat:2 KDF with zero deviation.
final class EarbudCounterpartyTests: XCTestCase {

    // MARK: - helpers

    private func hex(_ s: String) -> Data {
        precondition(s.count % 2 == 0)
        var d = Data(capacity: s.count / 2)
        var idx = s.startIndex
        while idx < s.endIndex {
            let next = s.index(idx, offsetBy: 2)
            d.append(UInt8(s[idx..<next], radix: 16)!)
            idx = next
        }
        return d
    }

    private func toHex(_ d: Data) -> String {
        d.map { String(format: "%02x", $0) }.joined()
    }

    /// The 1568-byte ML-KEM-1024 ciphertext the `incremental` /
    /// `mid-pi-bytes` KAT vectors use: bytes 0x00..0xff repeating.
    private func mlkem1024Ct(_ seed: Int) -> Data {
        Data((0..<1568).map { UInt8((seed + $0) & 0xff) })
    }

    /// Mirror of Android `FwPduCodec.buildHsrespForTest` — fragments the
    /// earbud ek into [idx|chunk≤200] PDUs + the [0xFF|x25519] terminator.
    private func buildHsresp(mlkemEk: Data, earbudX25519: Data) -> [Data] {
        precondition(mlkemEk.count == EarbudFwPduCodec.mlkem1024EkLen)
        precondition(earbudX25519.count == EarbudFwPduCodec.x25519PubLen)
        var out: [Data] = []
        var off = 0
        var idx = 0
        while off < mlkemEk.count {
            let n = min(EarbudFwPduCodec.fragPayloadMax, mlkemEk.count - off)
            var frag = Data([UInt8(idx)])
            frag.append(mlkemEk.subdata(in: off ..< off + n))
            out.append(frag)
            off += n
            idx += 1
        }
        var term = Data([UInt8(EarbudFwPduCodec.hsrespX25519Marker)])
        term.append(earbudX25519)
        out.append(term)
        return out
    }

    // MARK: - FwPduCodec layout

    func testHsinitLayout() {
        let pub = Data(repeating: 0xAB, count: 32)
        let pdu = EarbudFwPduCodec.buildHsinit(counter: 7, x25519Pub: pub)
        XCTAssertNotNil(pdu)
        XCTAssertEqual(pdu!.count, 33)
        XCTAssertEqual(pdu![0], 7)
        XCTAssertEqual(pdu!.subdata(in: 1..<33), pub)
        // Out-of-range counter / wrong pub size ⇒ nil (fail-closed).
        XCTAssertNil(EarbudFwPduCodec.buildHsinit(counter: 256, x25519Pub: pub))
        XCTAssertNil(EarbudFwPduCodec.buildHsinit(counter: 1, x25519Pub: Data(count: 31)))
    }

    func testHsfinFragmentationAndFwH7Counters() {
        let ct = mlkem1024Ct(0)
        let frags = EarbudFwPduCodec.buildHsfin(startCounter: 2, mlkemCiphertext: ct)
        XCTAssertNotNil(frags)
        // 1568 / 200 = 7.84 → 8 fragments.
        XCTAssertEqual(frags!.count, 8)
        var reassembled = Data()
        for (i, frag) in frags!.enumerated() {
            // FW-H7: strictly-increasing counter per fragment.
            XCTAssertEqual(Int(frag[0]), 2 + i)
            XCTAssertEqual(Int(frag[1]), i)
            reassembled.append(frag.subdata(in: 2 ..< frag.count))
        }
        XCTAssertEqual(reassembled, ct)
        // Counter window overflow ⇒ nil.
        XCTAssertNil(EarbudFwPduCodec.buildHsfin(startCounter: 249, mlkemCiphertext: ct))
    }

    func testHsrespReassemblerHappyPath() {
        let ek = Data((0..<1568).map { UInt8($0 & 0xff) })
        let x = Data(repeating: 0x42, count: 32)
        let r = EarbudFwPduCodec.HsrespReassembler()
        let pdus = buildHsresp(mlkemEk: ek, earbudX25519: x)
        for (i, pdu) in pdus.enumerated() {
            let res = r.offer(pdu)
            if i < pdus.count - 1 {
                XCTAssertEqual(res, .needMore)
            } else {
                XCTAssertEqual(res, .ok(mlkemEk: ek, earbudX25519: x))
            }
        }
    }

    func testHsrespReassemblerFailClosed() {
        // Out-of-order index aborts and latches.
        let r = EarbudFwPduCodec.HsrespReassembler()
        var frag = Data([1])  // index 1 first (expected 0)
        frag.append(Data(repeating: 0, count: 10))
        guard case .abort = r.offer(frag) else { return XCTFail("expected abort") }
        guard case .abort = r.offer(Data([0, 0, 0])) else { return XCTFail("abort must latch") }

        // Terminator before ek complete aborts.
        let r2 = EarbudFwPduCodec.HsrespReassembler()
        var ekFrag = Data([0])
        ekFrag.append(Data(repeating: 1, count: 100))
        XCTAssertEqual(r2.offer(ekFrag), .needMore)
        var term = Data([UInt8(EarbudFwPduCodec.hsrespX25519Marker)])
        term.append(Data(repeating: 2, count: 32))
        guard case .abort = r2.offer(term) else { return XCTFail("expected abort") }
    }

    // MARK: - Responder state machine (fake crypto)

    private final class FakeCrypto: EarbudHandshakeResponder.HybridCrypto {
        var x25519SsOverride: Data?
        func generateX25519() throws -> EarbudHandshakeResponder.X25519KeyPair {
            EarbudHandshakeResponder.X25519KeyPair(
                pub: Data(repeating: 0x11, count: 32),
                opaquePriv: Data(repeating: 0x22, count: 32))
        }
        func mlkemEncapsulate(earbudMlkemPk: Data) throws -> EarbudHandshakeResponder.MlkemEncaps {
            EarbudHandshakeResponder.MlkemEncaps(
                ciphertext: Data(repeating: 0x33, count: 1568),
                sharedSecret: Data(repeating: 0x44, count: 32))
        }
        func x25519Ecdh(ownPriv: Data, earbudX25519Pub: Data) throws -> Data {
            x25519SsOverride ?? Data(repeating: 0x55, count: 32)
        }
        func deriveSessionKey(mlkemSs: Data, x25519Ss: Data, mlkemCt: Data) throws -> Data {
            Data(repeating: 0x66, count: 32)
        }
    }

    func testResponderHappyPath() {
        let r = EarbudHandshakeResponder(crypto: FakeCrypto(), counter: 3)
        guard case .send(let initPdus) = r.start() else { return XCTFail("start must emit HSINIT") }
        XCTAssertEqual(initPdus.count, 1)
        XCTAssertEqual(Int(initPdus[0][0]), 3)
        XCTAssertEqual(initPdus[0].count, 33)

        let ek = Data((0..<1568).map { UInt8($0 & 0xff) })
        let pdus = buildHsresp(mlkemEk: ek, earbudX25519: Data(repeating: 0x77, count: 32))
        var last: EarbudHandshakeResponder.Step = .needMore
        for pdu in pdus { last = r.onInbound(pdu) }
        guard case .done(let hsfin, let key) = last else {
            return XCTFail("expected done, got \(last)")
        }
        XCTAssertEqual(key, Data(repeating: 0x66, count: 32))
        XCTAssertEqual(hsfin.count, 8)
        // FW-H7: HSINIT consumed 3 → HSFIN starts at 4.
        XCTAssertEqual(Int(hsfin[0][0]), 4)
        XCTAssertEqual(Int(hsfin[7][0]), 11)
        // One-shot: any further input is a terminal fail.
        guard case .fail = r.onInbound(Data([0])) else { return XCTFail("post-done input must fail") }
    }

    func testResponderRejectsAllZeroX25519FwH6() {
        let crypto = FakeCrypto()
        crypto.x25519SsOverride = Data(count: 32)  // all-zero (low-order point)
        let r = EarbudHandshakeResponder(crypto: crypto, counter: 1)
        _ = r.start()
        let pdus = buildHsresp(
            mlkemEk: Data(count: 1568),
            earbudX25519: Data(repeating: 1, count: 32))
        var last: EarbudHandshakeResponder.Step = .needMore
        for pdu in pdus { last = r.onInbound(pdu) }
        guard case .fail(let reason) = last else { return XCTFail("expected FW-H6 fail") }
        XCTAssertTrue(reason.contains("FW-H6"))
    }

    func testResponderInputBeforeStartFails() {
        let r = EarbudHandshakeResponder(crypto: FakeCrypto(), counter: 1)
        guard case .fail = r.onInbound(Data([0, 1])) else {
            return XCTFail("input before start must fail")
        }
    }

    // MARK: - CRUX KAT — seam pins the frozen hybrid-combine-kat:2 vectors
    //
    // Same pinned literals as Android `EarbudHandshakeCounterpartyKatTest`
    // (tools/kat/hybrid-combine/hybrid-combine-kat.json, schema :2).
    // Proves the iOS seam (EarbudHandshakeCrypto.deriveSessionKey) is the
    // unchanged production KDF — NOT a cryptographic change.

    func testSeamMatchesFrozenKatVectorsPskNull() throws {
        let ct = mlkem1024Ct(0)
        let vectors: [(String, String, String, String)] = [
            ("incremental",
             "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f",
             "202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f",
             "8d87db5e2eb1a2a97c58ff27309fa37af70900d1c6034e87e1b204b14c288fc7"),
            ("mid-pi-bytes",
             "243f6a8885a308d313198a2e03707344a4093822299f31d0082efa98ec4e6c89",
             "a4093822299f31d0082efa98ec4e6c89243f6a8885a308d313198a2e03707344",
             "0adaefe18a2a5e7fc344c833852f7953ce7681e45105c5898f73d121e6d47d3f"),
        ]
        for (label, pqcSsHex, xSsHex, expectedHex) in vectors {
            let viaSeam = try EarbudHandshakeCrypto(psk: nil)
                .deriveSessionKey(mlkemSs: hex(pqcSsHex), x25519Ss: hex(xSsHex), mlkemCt: ct)
            XCTAssertEqual(toHex(viaSeam), expectedHex,
                "[\(label)] seam must equal the frozen hybrid-combine-kat:2 vector")
            // Independent direct production-engine call — zero deviation.
            let direct = QAudionCallIntegration.deriveHybridSessionKey(
                pqcSs: hex(pqcSsHex), x25519Ss: hex(xSsHex), pqcCiphertext: ct, psk: nil)
            XCTAssertEqual(viaSeam, direct, "[\(label)] seam must equal direct engine derive")
        }
    }

    func testSeamMixesSovereignPskByteEqualToFrozenVectors() throws {
        let ct = mlkem1024Ct(0)
        // vector "psk-0xA5"
        let k1 = try EarbudHandshakeCrypto(psk: Data(repeating: 0xA5, count: 32))
            .deriveSessionKey(
                mlkemSs: hex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"),
                x25519Ss: hex("202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f"),
                mlkemCt: ct)
        XCTAssertEqual(toHex(k1), "7c0be795f7efc553132b17075bebb170f359805f72b753c2639a3d70c80a9430")
        // vector "psk-incremental"
        let k2 = try EarbudHandshakeCrypto(psk: hex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"))
            .deriveSessionKey(
                mlkemSs: hex("243f6a8885a308d313198a2e03707344a4093822299f31d0082efa98ec4e6c89"),
                x25519Ss: hex("a4093822299f31d0082efa98ec4e6c89243f6a8885a308d313198a2e03707344"),
                mlkemCt: ct)
        XCTAssertEqual(toHex(k2), "ccac4502a7829f7bf8a62d2844cf0fad39cbc3a69014cdb5b63a53674b6e1b05")
    }

    // MARK: - Wire framing (EARBUDPDU piggy-back)

    func testEarbudPduPiggyBackRoundTrip() {
        let pdu = Data([0x01, 0xFF, 0x42])
        let wire = CallPiggyBack.serializeEarbudPdu(callId: "abc-123", pdu: pdu)
        XCTAssertEqual(wire, "abc-123|EARBUDPDU:\(pdu.base64EncodedString())")
        guard case .earbudPdu(let callId, let parsed)? = CallPiggyBack.parse(wire) else {
            return XCTFail("round-trip parse failed")
        }
        XCTAssertEqual(callId, "abc-123")
        XCTAssertEqual(parsed, pdu)
        // Malformed base64 ⇒ nil (fail-closed, mirrors Android receive site).
        XCTAssertNil(CallPiggyBack.parse("abc|EARBUDPDU:!!!notb64"))
    }

    // MARK: - KCMAC piggy-back (PSK-mix ship-step-2, recognised-and-ignored)

    func testKcmacPiggyBackRecognisedAndDropped() {
        let wire = "abc-123|KCMAC:somePayload"
        guard case .kcmac(let callId, let raw)? = CallPiggyBack.parse(wire) else {
            return XCTFail("KCMAC piggy-back failed to parse")
        }
        XCTAssertEqual(callId, "abc-123")
        XCTAssertEqual(raw, "somePayload")
    }

    /// The critical property: a `"KCMAC:..."` payload must be fully consumed
    /// by `CallPiggyBack.parse` and MUST NOT be handed to
    /// `AndroidHandshakeEnvelope.parse` (the JSON HandshakeBundle decoder) —
    /// if it were, it would corrupt/desync unrelated handshake-bundle
    /// parsing for that call. `AppState.dispatchInboundOpaque` tries
    /// `CallPiggyBack.parse` BEFORE `AndroidHandshakeEnvelope.parse`, so this
    /// asserts the piggy-back parser alone already claims the payload.
    func testKcmacNeverReachesJsonHandshakeDecoder() {
        let wire = "abc-123|KCMAC:not-json-and-not-base64!!"
        // CallPiggyBack claims it...
        guard case .kcmac? = CallPiggyBack.parse(wire) else {
            return XCTFail("expected CallPiggyBack to consume the KCMAC payload")
        }
        // ...and the JSON envelope parser — which every real
        // AndroidHandshakeBundle payload starts with `{` for — never even
        // gets a shape it could parse: KCMAC's payload doesn't start with
        // `{`, so this must fail too, confirming there is no shared prefix
        // that could accidentally desync the JSON decoder.
        XCTAssertNil(AndroidHandshakeEnvelope.parse(wire))
    }

    // MARK: - FW-H7 counter allocator

    func testHsinitCounterAllocatorMonotonicAndExhaustion() {
        let suite = UserDefaults(suiteName: "earbud-test-\(UUID().uuidString)")!
        XCTAssertEqual(EarbudHsinitCounterAllocator.allocate(peerId: "p1", defaults: suite), 1)
        XCTAssertEqual(EarbudHsinitCounterAllocator.allocate(peerId: "p1", defaults: suite), 11)
        XCTAssertEqual(EarbudHsinitCounterAllocator.allocate(peerId: "p2", defaults: suite), 1)
        // Exhaust p1: starts 21,31,…,241 ok; 251 > 245 ⇒ nil.
        for _ in 0..<23 { _ = EarbudHsinitCounterAllocator.allocate(peerId: "p1", defaults: suite) }
        XCTAssertNil(EarbudHsinitCounterAllocator.allocate(peerId: "p1", defaults: suite))
        EarbudHsinitCounterAllocator.reset(peerId: "p1", defaults: suite)
        XCTAssertEqual(EarbudHsinitCounterAllocator.allocate(peerId: "p1", defaults: suite), 1)
    }
}
