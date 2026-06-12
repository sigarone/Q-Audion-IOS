import Foundation

/// Earbud firmware handshake PDU framing — direct port of Android
/// `FwPduCodec.kt` (ADP-A redesign), byte-identical wire layout per
/// qaudion-android-new/docs/superpowers/plans/2026-05-19-hwswitch-2a-fw-pdu-layout.md.
///
/// PURE, FAIL-CLOSED byte framing of the earbud firmware handshake PDUs
/// (HSINIT / HSRESP / HSFIN). Builds the SW-counterparty outbound PDUs
/// (HSINIT, HSFIN) and reassembles the inbound earbud HSRESP. NO crypto,
/// NO platform dependencies. Any malformed / out-of-range / duplicate /
/// oversized / wrong-total input ⇒ `.abort` with NO partial state.
///
/// Wire roles (earbud-relay-v1): the peer WITHOUT the earbud (always iOS
/// — there is no iOS earbud transport) is the COUNTERPARTY. It sends
/// HSINIT, receives the firmware's HSRESP relayed by the earbud-side
/// phone, and answers with HSFIN. The earbud-side phone is a
/// zero-knowledge relay (BLE GATT ↔ WS opaque_message).
public enum EarbudFwPduCodec {

    public static let mlkem1024EkLen = 1568   // earbud ML-KEM pubkey (HSRESP)
    public static let mlkem1024CtLen = 1568   // ML-KEM ciphertext (HSFIN)
    public static let x25519PubLen = 32
    public static let fragPayloadMax = 200    // ATT MTU 247 — per contract doc
    public static let hsrespX25519Marker = 0xFF
    private static let maxHsrespFrags = 64    // hard cap (bomb guard)

    /// HSINIT = [counter:1][x25519_pub:32].
    /// FW-H7: `counter` feeds the firmware's strictly-monotonic
    /// anti-replay gate — see `EarbudHsinitCounterAllocator`.
    public static func buildHsinit(counter: Int, x25519Pub: Data) -> Data? {
        guard (0...255).contains(counter), x25519Pub.count == x25519PubLen else { return nil }
        var pdu = Data(capacity: 1 + x25519PubLen)
        pdu.append(UInt8(counter))
        pdu.append(x25519Pub)
        return pdu
    }

    /// HSFIN = ordered [counter:1][index:1][ct_chunk] fragments,
    /// chunk ≤ fragPayloadMax.
    ///
    /// FW-H7: the firmware checks a strictly-monotonic counter on EVERY
    /// GATT write. After HSINIT consumed counter C, HSFIN fragment 0 MUST
    /// use C+1, fragment 1 C+2, … — `startCounter` is the value for
    /// fragment 0 (= HSINIT counter + 1).
    public static func buildHsfin(startCounter: Int, mlkemCiphertext: Data) -> [Data]? {
        guard (1...255).contains(startCounter),
              mlkemCiphertext.count == mlkem1024CtLen else { return nil }
        let fragCount = (mlkem1024CtLen + fragPayloadMax - 1) / fragPayloadMax
        guard startCounter + fragCount - 1 <= 255 else { return nil }
        var out: [Data] = []
        var off = 0
        var idx = 0
        while off < mlkemCiphertext.count {
            let n = min(fragPayloadMax, mlkemCiphertext.count - off)
            var frag = Data(capacity: 2 + n)
            frag.append(UInt8(startCounter + idx))
            frag.append(UInt8(idx))
            frag.append(mlkemCiphertext.subdata(in: off ..< off + n))
            out.append(frag)
            off += n
            idx += 1
        }
        return out
    }

    public enum HsrespResult: Equatable {
        case needMore
        case ok(mlkemEk: Data, earbudX25519: Data)
        case abort(reason: String)
    }

    /// Stateful, single-use reassembler for the inbound earbud HSRESP
    /// group. Fail-closed: once aborted it latches (every later offer ⇒
    /// `.abort`); no partial state is ever exposed.
    ///
    /// HSRESP wire (firmware → counterparty):
    ///   - ek fragments: [index:1][ek_chunk ≤ 200] in strict index order
    ///     (or a single unframed 1568-byte PDU carrying the whole ek)
    ///   - terminator:   [0xFF][x25519_pub:32]
    public final class HsrespReassembler {
        private var ek = Data(count: EarbudFwPduCodec.mlkem1024EkLen)
        private var ekFilled = 0
        private var nextIndex = 0
        private var earbudX25519 = Data(count: EarbudFwPduCodec.x25519PubLen)
        private var hasX25519 = false
        private var fragCount = 0
        private var aborted: String?
        private var done = false

        public init() {}

        public func offer(_ pdu: Data) -> HsrespResult {
            if let reason = aborted { return .abort(reason: reason) }
            if done { return abort("offer after complete") }
            guard !pdu.isEmpty else { return abort("empty pdu") }
            fragCount += 1
            if fragCount > EarbudFwPduCodec.maxHsrespFrags { return abort("too many fragments") }

            let tag = Int(pdu[pdu.startIndex])
            if pdu.count == EarbudFwPduCodec.mlkem1024EkLen {
                if ekFilled > 0 { return abort("ek already partially or fully filled") }
                ek = Data(pdu)
                ekFilled = EarbudFwPduCodec.mlkem1024EkLen
            } else if pdu.count == 1 + EarbudFwPduCodec.x25519PubLen,
                      tag == EarbudFwPduCodec.hsrespX25519Marker {
                if hasX25519 { return abort("duplicate x25519 fragment") }
                if ekFilled > 0 && ekFilled < EarbudFwPduCodec.mlkem1024EkLen {
                    return abort("terminator before ek complete")
                }
                earbudX25519 = pdu.subdata(in: pdu.startIndex + 1 ..< pdu.startIndex + 1 + EarbudFwPduCodec.x25519PubLen)
                hasX25519 = true
            } else {
                if pdu.count > 1 + EarbudFwPduCodec.fragPayloadMax { return abort("oversized fragment") }
                if tag == EarbudFwPduCodec.hsrespX25519Marker {
                    // Marker-tagged but wrong length (the well-formed marker
                    // case is handled above).
                    return abort("bad x25519 terminator len")
                }
                if tag != nextIndex { return abort("out-of-order/duplicate index") }
                let payload = pdu.count - 1
                if payload <= 0 { return abort("zero payload") }
                if ekFilled + payload > EarbudFwPduCodec.mlkem1024EkLen { return abort("ek overflow") }
                let chunk = pdu.subdata(in: pdu.startIndex + 1 ..< pdu.endIndex)
                ek.replaceSubrange(ekFilled ..< ekFilled + payload, with: chunk)
                ekFilled += payload
                nextIndex += 1
            }

            if ekFilled == EarbudFwPduCodec.mlkem1024EkLen && hasX25519 {
                done = true
                return .ok(mlkemEk: Data(ek), earbudX25519: Data(earbudX25519))
            }
            return .needMore
        }

        private func abort(_ why: String) -> HsrespResult {
            aborted = why
            ek = Data(count: EarbudFwPduCodec.mlkem1024EkLen)
            ekFilled = 0
            nextIndex = 0
            earbudX25519 = Data(count: EarbudFwPduCodec.x25519PubLen)
            hasX25519 = false
            done = false
            return .abort(reason: why)
        }
    }
}
