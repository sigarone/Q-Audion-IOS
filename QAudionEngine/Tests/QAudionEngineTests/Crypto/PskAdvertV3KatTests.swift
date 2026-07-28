import XCTest
import CryptoKit
@testable import QAudionEngine

// This file's Decodable structs mirror KAT JSON fixture keys verbatim
// (snake_case, no CodingKeys) — renaming would silently break decoding
// against the shared cross-platform fixture.
// swiftlint:disable identifier_name

/// Cross-platform KAT for `PskAdvertV3` (WIRE_SPEC §3.3.1).
///
/// Golden source: `bcrypto-server/tools/kat/psk-advert-v3/psk-advert-v3-kat.json`,
/// generated and self-verified by `tools/kat/gen_psk_advert_v3_kat.py`, which
/// writes all six fleet copies in one run — including the byte-copy under
/// `Crypto/Resources/` this test loads. Android (`PskAdvertV3KatTest.kt`) and
/// Desktop (`pskAdvertV3.kat.spec.ts`) assert against the same file.
///
/// If this fails, this platform's blinded advertisement diverges from the other
/// two, and the visible symptom is NOT a crash: two peers who genuinely share a
/// secret quietly fail to match, the PSK drops out of the session key, and the
/// call still connects. That silent-degradation failure mode is why the vectors
/// exist before the wiring.
final class PskAdvertV3KatTests: XCTestCase {

    // MARK: - Vector loading

    private struct Root: Decodable {
        let schema: String
        let nonce_vectors: [NonceVector]
        let tag_vectors: [TagVector]
        let match_vectors: [MatchVector]
    }

    private struct NonceVector: Decodable {
        let name: String
        let call_id: String
        let sender_x25519_pub: String
        let expected_nonce: String
    }

    private struct TagVector: Decodable {
        let name: String
        let psk: String
        let call_id: String
        let nonce: String
        let role: Int
        let expected_preimage: String
        let expected_tag: String
    }

    private struct ExpectedMatch: Decodable {
        let received_index: Int
        let local_index: Int
        let role: Int
    }

    private struct MatchVector: Decodable {
        let name: String
        let call_id: String
        let sender_nonce: String
        let received_tags: [String]
        let local_psks: [String]
        /// Absent-or-null in the JSON means "must not match".
        let expected: ExpectedMatch?
    }

    private func loadRoot() throws -> Root {
        guard let url = Bundle.module.url(forResource: "psk-advert-v3-kat", withExtension: "json") else {
            XCTFail("psk-advert-v3-kat.json not found in Bundle.module — is the .copy() entry in Package.swift?")
            throw XCTSkip("missing vectors")
        }
        return try JSONDecoder().decode(Root.self, from: try Data(contentsOf: url))
    }

    private func hex(_ s: String) -> Data {
        var out = Data(capacity: s.count / 2)
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(after: i)
            // Safe: only ever fed golden KAT hex strings, self-verified by
            // gen_psk_advert_v3_kat.py before being written to the fixture.
            // swiftlint:disable:next force_unwrapping
            out.append(UInt8(s[i...j], radix: 16)!)
            i = s.index(after: j)
        }
        return out
    }

    private func toHex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

    // MARK: - The vectors

    func testSchemaIsTheOneThisPortWasWrittenAgainst() throws {
        // Guards against a regenerated file with a changed shape passing silently
        // because every optional decode degraded to nil.
        XCTAssertEqual("qaudion-psk-advert-v3-kat:1", try loadRoot().schema)
    }

    func testReproducesEveryGoldenNonce() throws {
        let root = try loadRoot()
        XCTAssertFalse(root.nonce_vectors.isEmpty, "no nonce vectors loaded")
        for v in root.nonce_vectors {
            let got = PskAdvertV3.deriveNonce(
                callId: v.call_id,
                senderEphemeralX25519Pub: hex(v.sender_x25519_pub)
            )
            XCTAssertNotNil(got, "nonce nil in '\(v.name)'")
            XCTAssertEqual(v.expected_nonce, toHex(got ?? Data()), "nonce mismatch in '\(v.name)'")
            XCTAssertEqual(PskAdvertV3.nonceBytes, got?.count, "nonce width in '\(v.name)'")
        }
    }

    func testReproducesEveryGoldenTag() throws {
        let root = try loadRoot()
        XCTAssertFalse(root.tag_vectors.isEmpty, "no tag vectors loaded")
        for v in root.tag_vectors {
            let got = PskAdvertV3.tag(
                psk: hex(v.psk), callId: v.call_id, nonce: hex(v.nonce), role: v.role
            )
            XCTAssertNotNil(got, "tag nil in '\(v.name)'")
            XCTAssertEqual(v.expected_tag, toHex(got ?? Data()), "tag mismatch in '\(v.name)'")
            XCTAssertEqual(PskAdvertV3.tagBytes, got?.count, "tag width in '\(v.name)'")
        }
    }

    func testReproducesEveryGoldenMatchIncludingTheNoMatchCases() throws {
        let root = try loadRoot()
        XCTAssertFalse(root.match_vectors.isEmpty, "no match vectors loaded")
        for v in root.match_vectors {
            let got = PskAdvertV3.match(
                receivedTagsHex: v.received_tags,
                callId: v.call_id,
                senderNonce: hex(v.sender_nonce),
                localPsks: v.local_psks.map { hex($0) }
            )
            if let want = v.expected {
                XCTAssertEqual(
                    PskAdvertV3.Match(
                        receivedIndex: want.received_index,
                        localIndex: want.local_index,
                        role: want.role
                    ),
                    got,
                    "match mismatch in '\(v.name)'"
                )
            } else {
                XCTAssertNil(got, "expected no match in '\(v.name)', got \(String(describing: got))")
            }
        }
    }

    // MARK: - The properties the change exists for, asserted against the real
    // module rather than trusted from the generator

    func testOneSecretProducesUnrelatedTagsInTwoCalls() {
        let psk = Data((0..<32).map { UInt8($0) })
        let pubA = Data((0..<32).map { UInt8($0 &+ 1) })
        let pubB = Data((0..<32).map { UInt8($0 &+ 2) })
        let a = PskAdvertV3.tag(
            psk: psk, callId: "call-1",
            // Safe: 32-byte hardcoded pubA + short callId — deriveNonce only
            // returns nil for wrong-width keys or an oversized callId.
            // swiftlint:disable:next force_unwrapping
            nonce: PskAdvertV3.deriveNonce(callId: "call-1", senderEphemeralX25519Pub: pubA)!,
            role: PskAdvertV3.roleNfc
        // Safe: 32-byte psk + matching-width nonce + valid role constant.
        // swiftlint:disable:next force_unwrapping
        )!
        let b = PskAdvertV3.tag(
            psk: psk, callId: "call-2",
            // Safe: 32-byte hardcoded pubB + short callId, same as above.
            // swiftlint:disable:next force_unwrapping
            nonce: PskAdvertV3.deriveNonce(callId: "call-2", senderEphemeralX25519Pub: pubB)!,
            role: PskAdvertV3.roleNfc
        // Safe: 32-byte psk + matching-width nonce + valid role constant.
        // swiftlint:disable:next force_unwrapping
        )!
        XCTAssertNotEqual(
            toHex(a), toHex(b),
            "the same secret produced the same tag twice — the relay can link the two calls"
        )
    }

    func testTheRoleNeverAppearsOnTheWireAndIsStillRecovered() {
        let psk = Data((0..<32).map { UInt8(($0 * 7) & 0xFF) })
        let callId = "3f2b7c10-9a4d-4e11-8b62-0c5d7e91a204"
        let pub = Data((0..<32).map { UInt8($0 &+ 5) })

        // The sender records this secret as NFC-origin.
        let advert = PskAdvertV3.buildAdvertisement(
            callId: callId, ownEphemeralX25519Pub: pub,
            orderedEntries: [PskAdvertV3.Entry(psk: psk, role: PskAdvertV3.roleNfc)]
        // Safe: fixed UUID callId + 32-byte pub + 32-byte psk, well within contract.
        // swiftlint:disable:next force_unwrapping
        )!
        // Nothing in the wire value discloses the role: an ordinary-role tag over the
        // same key is equally valid-looking and simply different.
        let asOrdinary = PskAdvertV3.tag(
            psk: psk, callId: callId,
            // Safe: same fixed 32-byte pub + fixed callId used above.
            // swiftlint:disable:next force_unwrapping
            nonce: PskAdvertV3.deriveNonce(callId: callId, senderEphemeralX25519Pub: pub)!,
            role: PskAdvertV3.roleOrdinary
        // Safe: 32-byte psk + matching-width nonce + valid role constant.
        // swiftlint:disable:next force_unwrapping
        )!
        XCTAssertNotEqual(advert[0], toHex(asOrdinary))

        // The receiver holds the same material with NO idea how the peer labelled it
        // and still recovers role=1.
        let m = PskAdvertV3.matchAgainstPeer(
            receivedTagsHex: advert, callId: callId,
            peerEphemeralX25519Pub: pub, localPsks: [psk]
        )
        XCTAssertEqual(PskAdvertV3.Match(receivedIndex: 0, localIndex: 0, role: PskAdvertV3.roleNfc), m)
    }

    /// The receive path must survive a hostile list. A relay that corrupts one
    /// element must not be able to abort the handshake or skip past a later,
    /// legitimate match.
    func testMalformedPeerEntriesAreMissesNotCrashes() {
        let psk = Data((0..<32).map { UInt8($0 &+ 9) })
        let callId = "c"
        let pub = Data((0..<32).map { UInt8($0 &+ 3) })
        let good = PskAdvertV3.buildAdvertisement(
            callId: callId, ownEphemeralX25519Pub: pub,
            orderedEntries: [PskAdvertV3.Entry(psk: psk, role: PskAdvertV3.roleQr)]
        // Safe: short callId + 32-byte pub/psk + a single ordered entry, so
        // the result is non-nil and non-empty.
        // swiftlint:disable:next force_unwrapping
        )![0]

        let hostile = [
            "",                                             // empty
            "zz",                                           // non-hex
            "abc",                                          // odd length
            String(repeating: "00", count: 16),             // right form, wrong width
            String(repeating: "00", count: 64),             // too wide
            good,                                           // the legitimate one, last
        ]
        let m = PskAdvertV3.matchAgainstPeer(
            receivedTagsHex: hostile, callId: callId,
            peerEphemeralX25519Pub: pub, localPsks: [psk]
        )
        XCTAssertEqual(
            PskAdvertV3.Match(receivedIndex: 5, localIndex: 0, role: PskAdvertV3.roleQr), m,
            "a corrupted earlier element swallowed a later legitimate match"
        )
    }

    func testTheStaticFingerprintIsUnchangedFromV1() {
        // Still lc_hex(SHA-256(psk)): every off-wire consumer (vault names, kc_mac
        // mixedFingerprints, PskMix.mixId, the hw_only D4 intersect) depends on this
        // staying exactly what it always was.
        let psk = Data((0..<32).map { UInt8($0) })
        XCTAssertEqual(
            toHex(Data(SHA256.hash(data: psk))),
            PskAdvertV3.staticFingerprintHex(psk: psk)
        )
        XCTAssertEqual(64, PskAdvertV3.staticFingerprintHex(psk: psk).count)
    }

    func testALegacyStaticFingerprintAdvertIsACleanNoMatch() {
        // What a v3 receiver sees from a pre-v3 peer. It must be a no-match, not a
        // wrong match — and the CALLER is then responsible for saying so out loud
        // rather than silently deriving the session key without the PSK.
        let psk = Data((0..<32).map { UInt8($0 &+ 11) })
        let legacy = PskAdvertV3.staticFingerprintHex(psk: psk)
        XCTAssertNil(
            PskAdvertV3.matchAgainstPeer(
                receivedTagsHex: [legacy], callId: "call",
                peerEphemeralX25519Pub: Data(repeating: 7, count: 32), localPsks: [psk]
            )
        )
    }

    /// A malformed input must return nil, never trap: these run on wire data.
    func testMalformedOwnInputsReturnNilRatherThanTrapping() {
        XCTAssertNil(PskAdvertV3.deriveNonce(callId: "c", senderEphemeralX25519Pub: Data(repeating: 1, count: 31)))
        let nonce = Data(repeating: 2, count: 32)
        XCTAssertNil(PskAdvertV3.tag(psk: Data(repeating: 3, count: 31), callId: "c", nonce: nonce, role: 0))
        XCTAssertNil(PskAdvertV3.tag(psk: Data(repeating: 3, count: 32), callId: "c", nonce: Data(), role: 0))
        XCTAssertNil(PskAdvertV3.tag(psk: Data(repeating: 3, count: 32), callId: "c", nonce: nonce, role: 256))
        XCTAssertNil(PskAdvertV3.tag(psk: Data(repeating: 3, count: 32), callId: "c", nonce: nonce, role: -1))
        // A callId over 255 UTF-8 bytes is out of contract, not silently truncated.
        XCTAssertNil(PskAdvertV3.deriveNonce(
            callId: String(repeating: "a", count: 256),
            senderEphemeralX25519Pub: Data(repeating: 1, count: 32)
        ))
    }
}
// swiftlint:enable identifier_name
