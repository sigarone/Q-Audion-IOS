import XCTest
import CryptoKit
@testable import QAudionEngine

/// Covers the pinned wipe-signing pubkey build asset (TRUST-2,
/// `docs/security/CRYPTO_PROTOCOL_AUDIT_2026-09-01.md`) and the loader that
/// turns it into a `WipeCommandVerifier`. Mirrors
/// `EntitlementPublicKeyTests` — see that file's kdoc for the ship-guard
/// rationale (comparing decoded key BYTES, never PEM text, because of this
/// repo's CRLF/LF checkout mismatch) and why it stays deliberately skipped
/// until the real key lands.
final class WipeSigningPublicKeyTests: XCTestCase {

    /// Single switch for the ship-guard below. Flip to `false` in the SAME
    /// commit that swaps `Resources/wipe_signing_pubkey.pem` for the real
    /// bcrypto-server-issued key.
    ///
    /// FLIPPED 2026-09-02 — bcrypto-server generated its real wipe-signing
    /// keypair on first boot of the production deploy (pub
    /// hORZ2NjhScB3UVxyqHApIiHgjL+ddPuQ7oXm/NOn79s=); the asset below is
    /// that real key, not the throwaway placeholder.
    private static let assetIsStillThePlaceholder = false

    // MARK: - Ship-guard

    func testCommittedAssetIsNotStillThePlaceholderKey() throws {
        try XCTSkipIf(
            Self.assetIsStillThePlaceholder,
            """
            Blocked on bcrypto-server issuing the real wipe-signing public key \
            (TRUST-2) — confirmed absent from that sibling repo as of this \
            commit. This guard would fail on every run until it lands, \
            reddening the suite for a known, tracked, externally-blocked \
            reason. Re-arm it (set assetIsStillThePlaceholder = false) in the \
            SAME commit that swaps \
            Resources/wipe_signing_pubkey.pem for the real public key. Until \
            then every genuine server-signed remote_wipe command fails \
            verification against this placeholder — fail-closed (refuses to \
            wipe), which is the correct and intended state, not a bug to \
            silence by deleting this test.
            """
        )

        let raw = try XCTUnwrap(
            WipeSigningPublicKey.loadPinnedRawKey(),
            "pinned wipe-signing pubkey asset missing from Bundle.module — check the .copy() entry in Package.swift"
        )
        let placeholder = try XCTUnwrap(Data(base64Encoded: WipeSigningPublicKey.placeholderRawKeyBase64))
        XCTAssertNotEqual(
            raw, placeholder,
            """
            wipe_signing_pubkey.pem still holds the throwaway placeholder keypair — \
            swap in the real bcrypto-server-issued public key before this ships
            """
        )
    }

    // MARK: - Invariants that hold whichever key is pinned

    func testBundledAssetIsPresentAndExactly32Bytes() throws {
        let raw = try XCTUnwrap(
            WipeSigningPublicKey.loadPinnedRawKey(),
            "pinned wipe-signing pubkey asset missing from Bundle.module — check the .copy() entry in Package.swift"
        )
        XCTAssertEqual(raw.count, 32, "an Ed25519 raw public key is exactly 32 bytes")
        XCTAssertNoThrow(
            try Curve25519.Signing.PublicKey(rawRepresentation: raw),
            "whatever is pinned must be a usable Ed25519 key"
        )
    }

    func testMakeVerifierSucceedsAgainstTheBundledAsset() {
        XCTAssertNotNil(
            WipeSigningPublicKey.makeVerifier(),
            "makeVerifier() returned nil — asset missing, unparseable, or not a valid Ed25519 key"
        )
    }

    func testPlaceholderAssetMatchesTheKeyDocumentedInThisFile() throws {
        try XCTSkipUnless(Self.assetIsStillThePlaceholder, "asset swapped for the real key")
        let raw = try XCTUnwrap(WipeSigningPublicKey.loadPinnedRawKey())
        XCTAssertEqual(raw, Data(base64Encoded: WipeSigningPublicKey.placeholderRawKeyBase64))
    }

    // MARK: - PEM extraction (pure, no bundle)

    func testRawKeyExtractionTakesTheLast32BytesOfTheSpkiDer() throws {
        // Deliberately LF-joined with stray indentation — see
        // EntitlementPublicKey's kdoc: this repo has core.autocrlf=true and
        // no .gitattributes pinning .pem, so the same committed file is
        // CRLF on a Windows checkout, LF on the macOS CI runner.
        let pem = """
              -----BEGIN PUBLIC KEY-----
              MCowBQYDK2VwAyEAaF2vnjOZUNwivLypax55VnzgUejm8oGiEoa9A+aTFcY=
              -----END PUBLIC KEY-----
            """
        let raw = try XCTUnwrap(WipeSigningPublicKey.rawKey(fromSpkiPem: pem))
        XCTAssertEqual(raw.count, 32)
        XCTAssertEqual(raw, Data(base64Encoded: WipeSigningPublicKey.placeholderRawKeyBase64))
    }

    func testRawKeyExtractionIsIndifferentToCrlfVersusLf() throws {
        let body = "MCowBQYDK2VwAyEAaF2vnjOZUNwivLypax55VnzgUejm8oGiEoa9A+aTFcY="
        let lf = "-----BEGIN PUBLIC KEY-----\n\(body)\n-----END PUBLIC KEY-----\n"
        let crlf = "-----BEGIN PUBLIC KEY-----\r\n\(body)\r\n-----END PUBLIC KEY-----\r\n"
        XCTAssertEqual(
            WipeSigningPublicKey.rawKey(fromSpkiPem: lf),
            WipeSigningPublicKey.rawKey(fromSpkiPem: crlf)
        )
    }

    func testRawKeyExtractionRejectsGarbageInsteadOfReturningSomething() {
        XCTAssertNil(WipeSigningPublicKey.rawKey(fromSpkiPem: ""))
        XCTAssertNil(WipeSigningPublicKey.rawKey(fromSpkiPem: "not a pem at all"))
        XCTAssertNil(
            WipeSigningPublicKey.rawKey(fromSpkiPem: "-----BEGIN PUBLIC KEY-----\nAQID\n-----END PUBLIC KEY-----"),
            "a DER shorter than 32 bytes must fail, not be padded or truncated into a plausible-looking key"
        )
    }

    // MARK: - The key here must differ from the entitlement key (TRUST-2:
    // "do not reuse the OTA signing key — different purpose, different blast
    // radius if compromised")

    func testWipeSigningKeyIsNotTheSameAssetAsTheEntitlementKey() throws {
        let wipeRaw = try XCTUnwrap(WipeSigningPublicKey.loadPinnedRawKey())
        let entitlementRaw = try XCTUnwrap(EntitlementPublicKey.loadPinnedRawKey())
        XCTAssertNotEqual(
            wipeRaw, entitlementRaw,
            "TRUST-2 requires a DEDICATED wipe-signing key, never the OTA/entitlement key"
        )
    }
}
