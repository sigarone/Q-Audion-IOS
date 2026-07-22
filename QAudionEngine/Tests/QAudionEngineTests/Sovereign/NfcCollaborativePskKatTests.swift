import XCTest
import CryptoKit
@testable import QAudionEngine

/// W-NFCIOS (2026-07-22) — pins the NFC pairing PSK to the Android HCE peer.
///
/// Why a known-answer test and not a round-trip: the two halves of this ceremony
/// run on different operating systems in different languages, and every previous
/// bug here was a silent disagreement that no single-platform test could see.
/// Before this change iOS derived from `ecdh` alone, salted over the two
/// long-term identity keys, and discarded both entropies; Android derived from
/// `ecdh ‖ entropy_a ‖ entropy_b` salted over the ephemeral public keys. Both
/// sides were internally consistent and self-tested, and the pairing could never
/// have worked.
///
/// The vector below was computed independently (Python `cryptography`: X25519 +
/// HKDF-SHA256) from the construction in `NfcProtocol.kt:291-321`, so this test
/// checks iOS against the Android specification rather than against itself.
///
/// Android cannot consume this vector yet: `NfcProtocol.deriveCollaborativePsk`
/// takes its ephemeral key and entropy from internal state set by
/// `prepareCollaborativeExchange()`, with no seam to inject fixed values. Giving
/// it one and adding the mirror test is the follow-up that turns this from "iOS
/// matches the spec I read" into "both platforms match each other".
final class NfcCollaborativePskKatTests: XCTestCase {

    // Deliberately synthetic key material — counting up and counting down.
    private let aPrivHex = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
    private let bPrivHex = "fffefdfcfbfaf9f8f7f6f5f4f3f2f1f0efeeedecebeae9e8e7e6e5e4e3e2e1e0"
    private let entAHex  = "a0a1a2a3a4a5a6a7a8a9aaabacadaeafa0a1a2a3a4a5a6a7a8a9aaabacadaeaf"
    private let entBHex  = "b0b1b2b3b4b5b6b7b8b9babbbcbdbebfb0b1b2b3b4b5b6b7b8b9babbbcbdbebf"
    private let expectedPskHex = "4ba71e8285d957bcb62d6688368e1c0fb4b8e228335959c100d85b6de65388a3"

    private func hex(_ s: String) -> Data {
        var out = Data(); var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!)
            i = j
        }
        return out
    }
    private func hexString(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

    func testMatchesTheAndroidConstruction() throws {
        let aPriv = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: hex(aPrivHex))
        let bPriv = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: hex(bPrivHex))

        let psk = try NfcApduExchange.deriveCollaborativePsk(
            myEphPriv: aPriv,
            peerEphPub: bPriv.publicKey,
            entropyA: hex(entAHex),
            entropyB: hex(entBHex)
        )
        XCTAssertEqual(hexString(psk), expectedPskHex)
    }

    /// The salt sorts the two ephemeral public keys, so the responder computing
    /// the same ceremony from its own side must land on the same bytes. This is
    /// the property that lets both phones hold the identical key without either
    /// knowing which of them was the reader.
    func testBothSidesOfTheSameTapAgree() throws {
        let aPriv = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: hex(aPrivHex))
        let bPriv = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: hex(bPrivHex))

        let fromReader = try NfcApduExchange.deriveCollaborativePsk(
            myEphPriv: aPriv, peerEphPub: bPriv.publicKey,
            entropyA: hex(entAHex), entropyB: hex(entBHex))
        // The card holds the mirror-image inputs, but entropy_a stays the
        // INITIATOR's in both computations — that ordering is what the wire
        // fixes, and getting it backwards is the easiest way to reintroduce a
        // silent cross-platform split.
        let fromCard = try NfcApduExchange.deriveCollaborativePsk(
            myEphPriv: bPriv, peerEphPub: aPriv.publicKey,
            entropyA: hex(entAHex), entropyB: hex(entBHex))

        XCTAssertEqual(fromReader, fromCard)
        XCTAssertEqual(hexString(fromReader), expectedPskHex)
    }

    /// Swapping the entropies is not a no-op. Without this, an implementation
    /// that folded them in the wrong order would still pass the agreement test
    /// above and fail only against a real peer.
    func testEntropyOrderIsLoadBearing() throws {
        let aPriv = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: hex(aPrivHex))
        let bPriv = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: hex(bPrivHex))

        let swapped = try NfcApduExchange.deriveCollaborativePsk(
            myEphPriv: aPriv, peerEphPub: bPriv.publicKey,
            entropyA: hex(entBHex), entropyB: hex(entAHex))
        XCTAssertNotEqual(hexString(swapped), expectedPskHex)
    }

    /// The label is wire format shared with `NfcProtocol.kt:146`
    /// (`HKDF_INFO_COLLAB`). Editing the string silently repairs nothing and
    /// breaks every future pairing.
    func testInfoLabelIsFrozen() {
        XCTAssertEqual(
            String(data: HkdfLabels.nfcCollaborativePsk, encoding: .utf8),
            "Q-Audion NFC Collaborative PSK v1"
        )
    }
}
