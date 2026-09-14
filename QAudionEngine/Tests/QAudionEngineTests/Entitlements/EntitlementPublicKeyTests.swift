import XCTest
import CryptoKit
@testable import QAudionEngine

/// Covers the pinned entitlement pubkey build asset (design doc §3.5) and
/// the loader that turns it into an `EgtVerifier`.
///
/// The headline case here is `testCommittedAssetIsNotStillThePlaceholderKey`,
/// the ship-guard: nothing else mechanically stops
/// `Sources/QAudionEngine/Resources/bcrypto_entitlement_pubkey.pem` from
/// shipping with the throwaway test keypair still in it. If it did, every
/// real server-minted EGT would fail verification and the whole fleet would
/// resolve to Base — fail-closed, but a fleet-wide outage whose symptom is
/// nowhere near its cause. Android carries the same guard.
///
/// **Armed 2026-08-17:** the real `ent-v1` keypair now lives on the VPS
/// (server-generated via `auth.LoadOrCreateEd25519`, private half never
/// left the box — see `bcrypto-server`'s CLAUDE.md key-custody table for
/// the `BCRYPTO_ENTITLEMENTS_EDDSA_KEY_FILE` entry) and
/// `Sources/QAudionEngine/Resources/bcrypto_entitlement_pubkey.pem` was
/// swapped to match in the same commit.
final class EntitlementPublicKeyTests: XCTestCase {

    /// Single switch for the two mutually-exclusive cases below.
    private static let assetIsStillThePlaceholder = false

    // MARK: - Ship-guard

    func testCommittedAssetIsNotStillThePlaceholderKey() throws {
        try XCTSkipIf(
            Self.assetIsStillThePlaceholder,
            """
            Blocked on the server issuing the real ent-v1 entitlement public key, \
            which does not exist yet — this guard would fail on every run until it \
            does, reddening every subsequent task's suite for a known, tracked, \
            externally-blocked reason. Re-arm it (set assetIsStillThePlaceholder = \
            false) in the same commit that swaps \
            Sources/QAudionEngine/Resources/bcrypto_entitlement_pubkey.pem for the \
            real key. That is a hard prerequisite of Task 3 (CapabilityGate) — the \
            first task that puts this key on a path real users depend on. Do not \
            let it stay skipped past that point, and do not delete the test.
            """
        )

        let raw = try XCTUnwrap(
            EntitlementPublicKey.loadPinnedRawKey(),
            "pinned pubkey asset missing from Bundle.module — check the .copy() entry in Package.swift"
        )
        let placeholder = try XCTUnwrap(Data(base64Encoded: EntitlementPublicKey.placeholderRawKeyBase64))
        XCTAssertNotEqual(
            raw, placeholder,
            """
            bcrypto_entitlement_pubkey.pem still holds the throwaway test keypair — \
            swap in the real server ent-v1 public key before this ships
            """
        )
    }

    // MARK: - While it IS the placeholder, prove the whole chain works

    func testPlaceholderAssetLoadsAndVerifiesTheCommittedKatToken() throws {
        try XCTSkipUnless(
            Self.assetIsStillThePlaceholder,
            "the asset has been swapped for the real key; the KAT vectors are signed by the old throwaway key"
        )

        // End-to-end over the REAL bundled asset: file -> PEM parse -> raw
        // key -> EgtVerifier -> a real server-shaped token. Any broken link
        // (missing .copy() entry, wrong SPKI offset, corrupted PEM) fails
        // here rather than silently at first production use.
        let verifier = try XCTUnwrap(
            EntitlementPublicKey.makeVerifier(),
            "makeVerifier() returned nil — asset missing, unparseable, or not a valid Ed25519 key"
        )
        let claims = try XCTUnwrap(
            verifier.verify(Self.katValidToken),
            "the bundled placeholder key must verify the KAT vector it signed"
        )
        XCTAssertEqual(claims.sub, "user-kat-0001")
    }

    func testPlaceholderAssetMatchesTheKeyDocumentedInThisFile() throws {
        try XCTSkipUnless(Self.assetIsStillThePlaceholder, "asset swapped for the real key")

        let raw = try XCTUnwrap(EntitlementPublicKey.loadPinnedRawKey())
        XCTAssertEqual(raw, Data(base64Encoded: EntitlementPublicKey.placeholderRawKeyBase64))
    }

    // MARK: - Invariants that hold whichever key is pinned

    func testBundledAssetIsPresentAndExactly32Bytes() throws {
        let raw = try XCTUnwrap(
            EntitlementPublicKey.loadPinnedRawKey(),
            "pinned pubkey asset missing from Bundle.module — check the .copy() entry in Package.swift"
        )
        XCTAssertEqual(raw.count, 32, "an Ed25519 raw public key is exactly 32 bytes")
        XCTAssertNoThrow(
            try Curve25519.Signing.PublicKey(rawRepresentation: raw),
            "whatever is pinned must be a usable Ed25519 key"
        )
    }

    // MARK: - PEM extraction (pure, no bundle)

    func testRawKeyExtractionTakesTheLast32BytesOfTheSpkiDer() throws {
        // Deliberately LF-joined with stray indentation: this repo has
        // core.autocrlf=true and no .gitattributes pinning .pem, so the same
        // committed file is CRLF on a Windows checkout and LF on the macOS
        // CI runner. The extractor strips all whitespace precisely so the
        // pinned key cannot depend on which one it got — Android's guard
        // compared PEM *text*, silently never fired because of exactly this,
        // and had to be repaired after the fact.
        let pem = """
              -----BEGIN PUBLIC KEY-----
              MCowBQYDK2VwAyEAebVWLo/mVPlAeLES6KmLp5AfhTrmlb7X4OORC60ElmQ=
              -----END PUBLIC KEY-----
            """
        let raw = try XCTUnwrap(EntitlementPublicKey.rawKey(fromSpkiPem: pem))
        XCTAssertEqual(raw.count, 32)
        XCTAssertEqual(raw, Data(base64Encoded: EntitlementPublicKey.placeholderRawKeyBase64))
    }

    func testRawKeyExtractionIsIndifferentToCrlfVersusLf() throws {
        let body = "MCowBQYDK2VwAyEAebVWLo/mVPlAeLES6KmLp5AfhTrmlb7X4OORC60ElmQ="
        let lf = "-----BEGIN PUBLIC KEY-----\n\(body)\n-----END PUBLIC KEY-----\n"
        let crlf = "-----BEGIN PUBLIC KEY-----\r\n\(body)\r\n-----END PUBLIC KEY-----\r\n"
        XCTAssertEqual(
            EntitlementPublicKey.rawKey(fromSpkiPem: lf),
            EntitlementPublicKey.rawKey(fromSpkiPem: crlf)
        )
    }

    func testRawKeyExtractionRejectsGarbageInsteadOfReturningSomething() {
        XCTAssertNil(EntitlementPublicKey.rawKey(fromSpkiPem: ""))
        XCTAssertNil(EntitlementPublicKey.rawKey(fromSpkiPem: "not a pem at all"))
        XCTAssertNil(
            EntitlementPublicKey.rawKey(fromSpkiPem: "-----BEGIN PUBLIC KEY-----\nAQID\n-----END PUBLIC KEY-----"),
            "a DER shorter than 32 bytes must fail, not be padded or truncated into a plausible-looking key"
        )
    }

    /// Vector 1 from `EgtVerifierTests` — a real server-shaped EGT signed by
    /// the placeholder keypair. Duplicated rather than shared so that file's
    /// vectors stay a self-contained block that can be regenerated wholesale.
    private static let katValidToken =
        "eyJhbGciOiJFZERTQSIsImtpZCI6ImVudC12MSIsInR5cCI6IkJFR1QifQ" +
        ".eyJ2IjoxLCJkaWQiOiJkZXZpY2UtYWJjIiwiZGt0IjoiZGt0LXRodW1icHJpbnQtYWJjIiwicGtnIjpbImJhc2UiLCJwcm8iXSwiZmVhIjp7ImZlYXQuY2FsbHMudmlkZW8iOjE3MDAwMDAwMDAsImZlYXQuZmlsZXMiOjB9LCJsaW0iOnsibGltLmZpbGVfcXVvdGFfYnl0ZXMiOjIxNDc0ODM2NDgwLCJsaW0ubWF4X2RldmljZXMiOjN9LCJwb2wiOnsibWluX2Fzc3VyYW5jZSI6Im5vbmUiLCJvbl92aW9sYXRpb24iOiJ3YXJuIn0sImVlIjo3LCJzdWIiOiJ1c2VyLWthdC0wMDAxIiwiZXhwIjoxNzg2OTk1OTc1LCJpYXQiOjE3ODY5MDk1NzV9" +
        ".PfPFu4bjt1U7Q-7vojLT6FT3bk-oBlVWUocUMZsX0ObWgf3SMTquF6sNKMi8FAsUuww3B_jSAXqHu2Zy1fTdDg"
}
