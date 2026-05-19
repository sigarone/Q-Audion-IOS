import XCTest
@testable import QAudionEngine

/// Fuzz / property tests for the QR decode parsers:
/// - `IdentityQrCode.decode(string:)` — scheme / version / `:`-split /
///   base64 / checksum path.
/// - `DeviceLinkBinaryQR.decodeBlob(_:)` — 32B pubkey ‖ 4B length ‖
///   userId ‖ 16B auth, plus the trailing-byte / length-field math.
/// - `FastSetupQrCode.decode(url:)` — base64url ‖ JSON ‖ field coercion.
///
/// Property: any malformed / boundary / random / mutated / sliced
/// input must return `nil` or throw cleanly — never trap or OOB-read.
///
/// Includes two **regression cases for real bugs found by this fuzz
/// harness** and fixed wire-neutrally in the parsers:
///   1. `DeviceLinkBinaryQR.decodeBlob` indexed a non-zero-startIndex
///      `Data` slice with absolute offsets → OOB / garbage decode.
///   2. `FastSetupQrCode.decode` did `Int64(Double)` on the
///      `expires_at` field → trap on +inf / NaN / out-of-range.
final class QrPayloadFuzzTests: XCTestCase {

    // MARK: IdentityQrCode (string decode)

    func testIdentityQrStringDecodeFailsSoft() {
        // Random UTF-8-ish strings.
        var rng = FuzzRng(seed: 0x1DE0_0001)
        let charset = Array("ABCDEFabcdef0123456789:+/=qaudion-id .\u{0000}\u{FFFF}")
        for _ in 0..<6000 {
            let len = rng.int(80)
            var s = ""
            for _ in 0..<len { s.append(charset[rng.int(charset.count)]) }
            _ = try? (IdentityQrCode.decode(string: s))
        }
        // Structured-but-broken: right prefix, wrong everything else.
        let crafted = [
            "", ":", "::::", "qaudion-id", "qaudion-id:",
            "qaudion-id:abc:user:pk:ck",
            "qaudion-id:2:user:!!!notbase64!!!:ck",
            "qaudion-id:2:user::",
            "qaudion-id:999999999999999999999999:u:p:c",
            "qaudion-id:2:u:" + String(repeating: "A", count: 100000) + ":c",
            "qaudion-id:1:u:AAAA:BB",
            String(repeating: ":", count: 5000),
        ]
        for s in crafted {
            _ = try? (IdentityQrCode.decode(string: s))
        }
    }

    func testIdentityQrRoundTripStillWorks() throws {
        let id = IdentityQrCode.Identity(
            userId: "alice", pubkey: Data(repeating: 7, count: 32))
        let s = try IdentityQrCode.encode(identity: id)
        let back = try IdentityQrCode.decode(string: s)
        XCTAssertEqual(back.userId, "alice")
        XCTAssertEqual(back.pubkey, id.pubkey)
        // Mutating the encoded string must never crash the decoder.
        for m in FuzzCorpus.mutations(of: Data(s.utf8),
                                      count: 3000, rngSeed: 0xABCD) {
            let str = String(decoding: m, as: UTF8.self)
            _ = try? (IdentityQrCode.decode(string: str))
        }
    }

    // MARK: DeviceLinkBinaryQR (blob decode)

    /// Random + fill + boundary blobs, each also fed as a non-zero
    /// `startIndex` slice. The sliced variant is the regression guard
    /// for the absolute-index bug.
    func testDeviceLinkBlobDecodeFailsSoft() {
        let minSize = DeviceLinkBinaryQR.pubkeyLength
            + DeviceLinkBinaryQR.lengthFieldBytes
            + DeviceLinkBinaryQR.authCodeLength       // 52
        let maxLen = minSize + 1024 + 64
        for d in FuzzCorpus.fillCorpus(maxLen: maxLen) {
            _ = try? (DeviceLinkBinaryQR.decodeBlob(d))
            _ = try? (DeviceLinkBinaryQR.decodeBlob(FuzzCorpus.sliced(d)))
        }
        for d in FuzzCorpus.randomCorpus(maxLen: maxLen, perLength: 4,
                                         seed: 0x0117_4B00) {
            _ = try? (DeviceLinkBinaryQR.decodeBlob(d))
            _ = try? (DeviceLinkBinaryQR.decodeBlob(FuzzCorpus.sliced(d)))
        }
        // Adversarial length field: declare a huge userId length but
        // supply a short blob (must reject, never OOM / OOB).
        for declared: UInt32 in [0, 1, 0xFFFF_FFFF, 1025, 1024, 0x7FFF_FFFF] {
            var blob = Data(repeating: 0, count: 32)        // pubkey
            blob.append(UInt8((declared >> 24) & 0xFF))
            blob.append(UInt8((declared >> 16) & 0xFF))
            blob.append(UInt8((declared >> 8) & 0xFF))
            blob.append(UInt8(declared & 0xFF))
            blob.append(Data(repeating: 0x41, count: 8))    // short body
            blob.append(Data(repeating: 0, count: 16))      // auth
            _ = try? (DeviceLinkBinaryQR.decodeBlob(blob))
            _ = try? (DeviceLinkBinaryQR.decodeBlob(FuzzCorpus.sliced(blob)))
        }
    }

    /// REGRESSION: a valid blob, decoded from a non-zero-startIndex
    /// slice, must produce the SAME result as from a zero-based copy.
    /// Before the fix this OOB-read or decoded garbage.
    func testDeviceLinkSliceIndexingRegression() throws {
        let pubkey = Data(repeating: 0x11, count: 32)
        let userId = "alice@host"
        let authCode = Data(repeating: 0x22, count: 16)
        let blob = try DeviceLinkBinaryQR.encodeBlob(
            pubkey: pubkey, userId: userId, authCode: authCode)

        let fromZeroBased = try DeviceLinkBinaryQR.decodeBlob(blob)
        let slicedView = FuzzCorpus.sliced(blob, prefixPad: 13)
        XCTAssertNotEqual(slicedView.startIndex, 0,
                          "test setup: expected a non-zero startIndex slice")
        let fromSlice = try DeviceLinkBinaryQR.decodeBlob(slicedView)

        XCTAssertEqual(fromZeroBased, fromSlice)
        XCTAssertEqual(fromSlice.userId, userId)
        XCTAssertEqual(fromSlice.pubkey, pubkey)
        XCTAssertEqual(fromSlice.authCode, authCode)
    }

    // MARK: FastSetupQrCode (url → base64url → JSON)

    func testFastSetupDecodeFailsSoft() {
        var rng = FuzzRng(seed: 0xFA57_5E70)
        for _ in 0..<3000 {
            let blob = rng.bytes(rng.int(256))
            let b64 = blob.base64UrlEncodedNoPadding()
            if let url = URL(string: "qaudion://setup/\(b64)") {
                _ = try? (FastSetupQrCode.decode(url: url))
            }
        }
        // Wrong scheme / host / empty path.
        for s in ["http://setup/AAAA", "qaudion://link/AAAA",
                  "qaudion://setup/", "qaudion://setup",
                  "qaudion://setup/%%%%", "notaurl"] {
            if let url = URL(string: s) {
                _ = try? (FastSetupQrCode.decode(url: url))
            }
        }
    }

    /// REGRESSION: `expires_at` as a JSON number that maps to a
    /// non-finite / out-of-range Double previously trapped on
    /// `Int64(Double)`. Must now throw cleanly.
    func testFastSetupExpiresAtDoubleTrapRegression() {
        let psk = Data(repeating: 0x33, count: 32).base64EncodedString()
        let evilExpiries = [
            "1e400",                       // → +inf
            "-1e400",                      // → -inf
            "9e99",                        // far above Int64.max
            "-9e99",                       // far below Int64.min
            "9223372036854775808.0",       // Int64.max + 1
        ]
        for ev in evilExpiries {
            let json = """
            {"v":1,"user_id":"u","psk":"\(psk)","extension":null,\
            "expires_at":\(ev),"server":"https://example.com"}
            """
            let blob = Data(json.utf8).base64UrlEncodedNoPadding()
            guard let url = URL(string: "qaudion://setup/\(blob)") else {
                XCTFail("could not build test url"); continue
            }
            // The contract: a clean throw, NOT a process-killing trap.
            XCTAssertThrowsError(try FastSetupQrCode.decode(url: url))
        }
    }
}
