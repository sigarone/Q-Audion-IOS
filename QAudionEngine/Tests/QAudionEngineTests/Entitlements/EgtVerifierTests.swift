import XCTest
import CryptoKit
@testable import QAudionEngine

/// KAT (known-answer test) coverage for `EgtVerifier` against REAL EGTs
/// signed by the server's actual `mintEGT`/`EGTClaims`/`EGTPolicy` types
/// (`cmd/bcrypto-lite/entitlements_egt.go` in `bcrypto-server`), generated
/// by a throwaway `go test` scratch file (never committed) with a
/// deterministic test-only Ed25519 keypair — NOT the production `ent-v1`
/// key. These are the EXACT SAME wire-format token strings Android's
/// `EgtVerifierTest.kt` committed (same test keypair, same
/// `cmd/bcrypto-lite/zzscratch_egt_kat_gen_test.go` scratch run,
/// 2026-08-16) — a compact JWS is a plain UTF-8 string, so reusing them
/// verbatim gives REAL cross-platform interop confidence (design doc §13)
/// rather than two independently-generated vector sets that could both be
/// internally self-consistent yet silently diverge from the real wire
/// format in the same way.
///
/// Test pubkey SPKI PEM (same key Android's test file documents):
/// ```
/// -----BEGIN PUBLIC KEY-----
/// MCowBQYDK2VwAyEAebVWLo/mVPlAeLES6KmLp5AfhTrmlb7X4OORC60ElmQ=
/// -----END PUBLIC KEY-----
/// ```
/// The last 32 bytes of that SPKI DER (raw Ed25519 public key, no ASN.1
/// wrapper) are `pinnedPublicKeyRawBase64` below — `Curve25519.Signing
/// .PublicKey(rawRepresentation:)` wants the raw key, not the SPKI blob.
///
/// `sub`/`did`/`ee` matching against the logged-in user/epoch is
/// `CapabilityGate`'s job (Task 3), not `EgtVerifier`'s — those design-doc
/// §13 cases are covered there, not here.
final class EgtVerifierTests: XCTestCase {

    private var verifier: EgtVerifier!

    /// Raw 32-byte Ed25519 public key = last 32 bytes of the test SPKI PEM
    /// documented above.
    private static let pinnedPublicKeyRawBase64 = "ebVWLo/mVPlAeLES6KmLp5AfhTrmlb7X4OORC60ElmQ="

    override func setUp() {
        super.setUp()
        let raw = Data(base64Encoded: Self.pinnedPublicKeyRawBase64)!
        verifier = EgtVerifier(pinnedPublicKeyRaw: raw)
    }

    override func tearDown() {
        verifier = nil
        super.tearDown()
    }

    // MARK: - Vector 1: valid

    func testValidTokenVerifiesAndDecodesClaimsMatchingTheSignedPayload() {
        let claims = verifier.verify(Self.valid)
        XCTAssertNotNil(claims)
        guard let claims else { return }
        XCTAssertEqual(claims.v, 1)
        XCTAssertEqual(claims.sub, "user-kat-0001")
        XCTAssertEqual(claims.did, "device-abc")
        XCTAssertEqual(claims.dkt, "dkt-thumbprint-abc")
        XCTAssertEqual(claims.pkg, ["base", "pro"])
        XCTAssertEqual(claims.fea["feat.files"], 0)
        XCTAssertEqual(claims.fea["feat.calls.video"], 1_700_000_000)
        XCTAssertEqual(claims.lim["lim.file_quota_bytes"], 21_474_836_480)
        XCTAssertEqual(claims.lim["lim.max_devices"], 3)
        XCTAssertEqual(claims.pol.minAssurance, "none")
        XCTAssertEqual(claims.pol.onViolation, "warn")
        XCTAssertEqual(claims.ee, 7)
        XCTAssertNil(claims.epr)
    }

    // MARK: - Vector 2: flipped signature byte

    func testFlippedSignatureByteFailsVerification() {
        XCTAssertNil(verifier.verify(Self.flippedSignatureByte))
    }

    // MARK: - Vector 3: alg confusion to HS256, garbage signature

    func testAlgConfusionToHS256WithAGarbageSignatureIsRejected() {
        // The paired signature is 3 garbage bytes -- nowhere near a valid
        // 64-byte Ed25519 signature. A nil result alone would not
        // distinguish "alg gate fired" from "signature check failed on
        // garbage bytes" -- the mechanical ordering proof below settles
        // that. This is the plain real-vector regression check.
        XCTAssertNil(verifier.verify(Self.algConfusionHS256))
    }

    // MARK: - Mechanical proof of ordering: the alg gate fires BEFORE any
    //         signature bytes are decoded or checked, not just "also rejects"

    func testAlgPinningHappensBeforeAnySignatureVerifyCall() {
        var verifyCallCount = 0
        let spyVerifier = EgtVerifier(verifySignatureOverride: { _, _ in
            verifyCallCount += 1
            return false
        })
        XCTAssertNil(spyVerifier.verify(Self.algConfusionHS256))
        XCTAssertNil(spyVerifier.verify(Self.algNoneEmptySig))
        XCTAssertEqual(
            verifyCallCount, 0,
            "the alg gate must reject before the signature-verify primitive is ever invoked"
        )
    }

    // MARK: - Vector 4: classic alg=none attack, empty signature

    func testAlgNoneWithAnEmptySignatureIsRejected() {
        XCTAssertNil(verifier.verify(Self.algNoneEmptySig))
    }

    // MARK: - Vector 5: expired envelope + expired feature, still validly signed

    func testAnExpiredEnvelopeAndAnExpiredFeatureStillVerifyAndDecode() {
        // design doc §3.2: exp is a refresh target, not a kill switch.
        // EgtVerifier must not treat a signed-but-expired token as
        // invalid -- CapabilityGate (Task 3) decides what to do with an
        // expired fea entry at use time.
        let claims = verifier.verify(Self.expiredEnvelopeAndFeature)
        XCTAssertNotNil(claims)
        guard let claims else { return }
        XCTAssertEqual(claims.sub, "user-kat-0001")
        XCTAssertLessThan(claims.exp, Int64(Date().timeIntervalSince1970), "exp should be in the past")
        XCTAssertEqual(claims.fea["feat.files"], 1_000_000_000)
    }

    // MARK: - Vector 6: kid does not match "ent-v1" but is signed by the same pinned key

    func testAKidOtherThanThePinnedOneStillVerifiesBecauseKidIsInformationalNotAKeyLookup() {
        // Single-pinned-key model (design doc §3.5 describes a FUTURE
        // cross-signed rotation this task does not build): kid is only
        // checked to be present as a non-empty string. It is never used
        // to select which key verifies the signature, so a token signed
        // by the one pinned key but carrying an unrecognized kid must
        // still verify -- otherwise kid would silently become a
        // rejection lever with no actual security benefit (the signature
        // check is what matters).
        XCTAssertNotNil(verifier.verify(Self.kidMismatchSameKey))
    }

    // MARK: - Vector 7: base-only user, no pro features

    func testABaseOnlyTokenVerifiesWithAnEmptyFeaMap() {
        let claims = verifier.verify(Self.baseOnlyUser)
        XCTAssertNotNil(claims)
        guard let claims else { return }
        XCTAssertEqual(claims.pkg, ["base"])
        XCTAssertTrue(claims.fea.isEmpty)
    }

    // MARK: - Structural malformation -- no real signature needed

    func testATokenThatIsNotExactlyThreeDotSeparatedPartsIsRejected() {
        XCTAssertNil(verifier.verify("only.two"))
        XCTAssertNil(verifier.verify("way.too.many.parts.here"))
        XCTAssertNil(verifier.verify("nodotsatall"))
        XCTAssertNil(verifier.verify(""))
    }

    func testNonBase64UrlHeaderIsRejected() {
        let payloadAndSig = Self.valid.split(separator: ".", maxSplits: 1)[1]
        XCTAssertNil(verifier.verify("not!valid!base64.\(payloadAndSig)"))
    }

    func testAHeaderThatIsValidBase64UrlButNotJsonIsRejected() {
        let notJson = base64urlEncode(Data("not json at all".utf8))
        let parts = Self.valid.split(separator: ".")
        XCTAssertNil(verifier.verify("\(notJson).\(parts[1]).\(parts[2])"))
    }

    // MARK: - Round-trip sanity: this test file's own signer against this
    //         test file's own verifier, independent of the committed KAT
    //         strings above (catches a bug that happens to affect both the
    //         KAT generation off-platform AND this file's parsing the same way).

    func testARoundTripTokenSignedWithAFreshKeypairVerifiesAndParses() throws {
        let priv = Curve25519.Signing.PrivateKey()
        let pub = priv.publicKey
        let header = #"{"alg":"EdDSA","kid":"ent-v1","typ":"BEGT"}"#
        let payload = """
        {"v":1,"sub":"user-a","did":"device-1","dkt":"","pkg":["base","pro"],\
        "fea":{"feat.files":0},"lim":{},\
        "pol":{"min_assurance":"none","on_violation":"warn"},\
        "ee":5,"iat":1755212345,"exp":1755298745}
        """
        let signedPart = "\(base64urlEncode(Data(header.utf8))).\(base64urlEncode(Data(payload.utf8)))"
        let sig = try priv.signature(for: Data(signedPart.utf8))
        let token = "\(signedPart).\(base64urlEncode(sig))"

        let freshVerifier = EgtVerifier(pinnedPublicKeyRaw: pub.rawRepresentation)
        let claims = freshVerifier?.verify(token)
        XCTAssertNotNil(claims)
        XCTAssertEqual(claims?.sub, "user-a")
        XCTAssertEqual(claims?.did, "device-1")
        XCTAssertEqual(claims?.fea["feat.files"], 0)
        XCTAssertEqual(claims?.ee, 5)
    }

    func testARoundTripTokenSignedByAWrongKeyFailsVerification() throws {
        let priv = Curve25519.Signing.PrivateKey()
        let otherPriv = Curve25519.Signing.PrivateKey() // wrong key signs it
        let header = #"{"alg":"EdDSA","kid":"ent-v1","typ":"BEGT"}"#
        let payload = """
        {"v":1,"sub":"user-a","did":"d","dkt":"","pkg":["base"],\
        "fea":{},"lim":{},\
        "pol":{"min_assurance":"none","on_violation":"warn"},\
        "ee":0,"iat":0,"exp":9999999999}
        """
        let signedPart = "\(base64urlEncode(Data(header.utf8))).\(base64urlEncode(Data(payload.utf8)))"
        let sig = try otherPriv.signature(for: Data(signedPart.utf8))
        let token = "\(signedPart).\(base64urlEncode(sig))"

        let freshVerifier = EgtVerifier(pinnedPublicKeyRaw: priv.publicKey.rawRepresentation)
        XCTAssertNil(freshVerifier?.verify(token))
    }

    // MARK: - Vectors (real, server-signed -- see file header)

    private static let valid =
        "eyJhbGciOiJFZERTQSIsImtpZCI6ImVudC12MSIsInR5cCI6IkJFR1QifQ" +
        ".eyJ2IjoxLCJkaWQiOiJkZXZpY2UtYWJjIiwiZGt0IjoiZGt0LXRodW1icHJpbnQtYWJjIiwicGtnIjpbImJhc2UiLCJwcm8iXSwiZmVhIjp7ImZlYXQuY2FsbHMudmlkZW8iOjE3MDAwMDAwMDAsImZlYXQuZmlsZXMiOjB9LCJsaW0iOnsibGltLmZpbGVfcXVvdGFfYnl0ZXMiOjIxNDc0ODM2NDgwLCJsaW0ubWF4X2RldmljZXMiOjN9LCJwb2wiOnsibWluX2Fzc3VyYW5jZSI6Im5vbmUiLCJvbl92aW9sYXRpb24iOiJ3YXJuIn0sImVlIjo3LCJzdWIiOiJ1c2VyLWthdC0wMDAxIiwiZXhwIjoxNzg2OTk1OTc1LCJpYXQiOjE3ODY5MDk1NzV9" +
        ".PfPFu4bjt1U7Q-7vojLT6FT3bk-oBlVWUocUMZsX0ObWgf3SMTquF6sNKMi8FAsUuww3B_jSAXqHu2Zy1fTdDg"

    private static let flippedSignatureByte =
        "eyJhbGciOiJFZERTQSIsImtpZCI6ImVudC12MSIsInR5cCI6IkJFR1QifQ" +
        ".eyJ2IjoxLCJkaWQiOiJkZXZpY2UtYWJjIiwiZGt0IjoiZGt0LXRodW1icHJpbnQtYWJjIiwicGtnIjpbImJhc2UiLCJwcm8iXSwiZmVhIjp7ImZlYXQuY2FsbHMudmlkZW8iOjE3MDAwMDAwMDAsImZlYXQuZmlsZXMiOjB9LCJsaW0iOnsibGltLmZpbGVfcXVvdGFfYnl0ZXMiOjIxNDc0ODM2NDgwLCJsaW0ubWF4X2RldmljZXMiOjN9LCJwb2wiOnsibWluX2Fzc3VyYW5jZSI6Im5vbmUiLCJvbl92aW9sYXRpb24iOiJ3YXJuIn0sImVlIjo3LCJzdWIiOiJ1c2VyLWthdC0wMDAxIiwiZXhwIjoxNzg2OTk1OTc1LCJpYXQiOjE3ODY5MDk1NzV9" +
        ".PfPFu4bjt1U7Q-7vojLT6FT3bk-oBlVWUocUMZsX0ObWgf3SMTquF6sNKMi8FAsUuww3B_jSAXqHu2Zy1fTdDw"

    private static let algConfusionHS256 =
        "eyJhbGciOiJIUzI1NiIsInR5cCI6IkJFR1QiLCJraWQiOiJlbnQtdjEifQ" +
        ".eyJ2IjoxLCJkaWQiOiJkZXZpY2UtYWJjIiwiZGt0IjoiZGt0LXRodW1icHJpbnQtYWJjIiwicGtnIjpbImJhc2UiLCJwcm8iXSwiZmVhIjp7ImZlYXQuY2FsbHMudmlkZW8iOjE3MDAwMDAwMDAsImZlYXQuZmlsZXMiOjB9LCJsaW0iOnsibGltLmZpbGVfcXVvdGFfYnl0ZXMiOjIxNDc0ODM2NDgwLCJsaW0ubWF4X2RldmljZXMiOjN9LCJwb2wiOnsibWluX2Fzc3VyYW5jZSI6Im5vbmUiLCJvbl92aW9sYXRpb24iOiJ3YXJuIn0sImVlIjo3LCJzdWIiOiJ1c2VyLWthdC0wMDAxIiwiZXhwIjoxNzg2OTk1OTc1LCJpYXQiOjE3ODY5MDk1NzV9" +
        ".AQID"

    private static let algNoneEmptySig =
        "eyJhbGciOiJub25lIiwidHlwIjoiQkVHVCIsImtpZCI6ImVudC12MSJ9" +
        ".eyJ2IjoxLCJkaWQiOiJkZXZpY2UtYWJjIiwiZGt0IjoiZGt0LXRodW1icHJpbnQtYWJjIiwicGtnIjpbImJhc2UiLCJwcm8iXSwiZmVhIjp7ImZlYXQuY2FsbHMudmlkZW8iOjE3MDAwMDAwMDAsImZlYXQuZmlsZXMiOjB9LCJsaW0iOnsibGltLmZpbGVfcXVvdGFfYnl0ZXMiOjIxNDc0ODM2NDgwLCJsaW0ubWF4X2RldmljZXMiOjN9LCJwb2wiOnsibWluX2Fzc3VyYW5jZSI6Im5vbmUiLCJvbl92aW9sYXRpb24iOiJ3YXJuIn0sImVlIjo3LCJzdWIiOiJ1c2VyLWthdC0wMDAxIiwiZXhwIjoxNzg2OTk1OTc1LCJpYXQiOjE3ODY5MDk1NzV9" +
        "."

    private static let expiredEnvelopeAndFeature =
        "eyJhbGciOiJFZERTQSIsImtpZCI6ImVudC12MSIsInR5cCI6IkJFR1QifQ" +
        ".eyJ2IjoxLCJkaWQiOiJkZXZpY2UtYWJjIiwiZGt0IjoiZGt0LXRodW1icHJpbnQtYWJjIiwicGtnIjpbImJhc2UiLCJwcm8iXSwiZmVhIjp7ImZlYXQuZmlsZXMiOjEwMDAwMDAwMDB9LCJsaW0iOnsibGltLmZpbGVfcXVvdGFfYnl0ZXMiOjIxNDc0ODM2NDgwLCJsaW0ubWF4X2RldmljZXMiOjN9LCJwb2wiOnsibWluX2Fzc3VyYW5jZSI6Im5vbmUiLCJvbl92aW9sYXRpb24iOiJ3YXJuIn0sImVlIjo3LCJzdWIiOiJ1c2VyLWthdC0wMDAxIiwiZXhwIjoxNzg2ODIzMTc1LCJpYXQiOjE3ODY3MzY3NzV9" +
        ".nflPgAyD0Z0GVdS62mEIuAp_DUfr7TAi5cK1ssDx54_KSTNxulwZips62MzG2_eLGOkq2YZ5XbInTROf-RbDCg"

    private static let kidMismatchSameKey =
        "eyJhbGciOiJFZERTQSIsImtpZCI6ImVudC12Mi1ub3QteWV0LXRydXN0ZWQiLCJ0eXAiOiJCRUdUIn0" +
        ".eyJ2IjoxLCJkaWQiOiJkZXZpY2UtYWJjIiwiZGt0IjoiZGt0LXRodW1icHJpbnQtYWJjIiwicGtnIjpbImJhc2UiLCJwcm8iXSwiZmVhIjp7ImZlYXQuY2FsbHMudmlkZW8iOjE3MDAwMDAwMDAsImZlYXQuZmlsZXMiOjB9LCJsaW0iOnsibGltLmZpbGVfcXVvdGFfYnl0ZXMiOjIxNDc0ODM2NDgwLCJsaW0ubWF4X2RldmljZXMiOjN9LCJwb2wiOnsibWluX2Fzc3VyYW5jZSI6Im5vbmUiLCJvbl92aW9sYXRpb24iOiJ3YXJuIn0sImVlIjo3LCJzdWIiOiJ1c2VyLWthdC0wMDAxIiwiZXhwIjoxNzg2OTk1OTc1LCJpYXQiOjE3ODY5MDk1NzV9" +
        ".VsIy-04fuTWtjYgUUvXRbqJYSWFyZyJcNwLDeP_7WWdqyoYW51O2EkpFPGL8IikBRFN84fzcr6zo3NGTO0KvDw"

    private static let baseOnlyUser =
        "eyJhbGciOiJFZERTQSIsImtpZCI6ImVudC12MSIsInR5cCI6IkJFR1QifQ" +
        ".eyJ2IjoxLCJkaWQiOiJkZXZpY2UtZGVmIiwiZGt0IjoiZGt0LXRodW1icHJpbnQtZGVmIiwicGtnIjpbImJhc2UiXSwiZmVhIjp7fSwibGltIjp7ImxpbS5tYXhfZGV2aWNlcyI6M30sInBvbCI6eyJtaW5fYXNzdXJhbmNlIjoibm9uZSIsIm9uX3Zpb2xhdGlvbiI6Indhcm4ifSwiZWUiOjEsInN1YiI6InVzZXIta2F0LTAwMDItYmFzZSIsImV4cCI6MTc4Njk5NTk3NSwiaWF0IjoxNzg2OTA5NTc1fQ" +
        ".5ysbDWa9TUauYWJdvcoAbeiJSCZRKPTbUfCrvYuXUx4cJHzg7cTKFBDSA7Lotl9IcDO1Quo4Tbqu6VQWwWSNAQ"
}

// MARK: - Test-only base64url helper (standard base64url-no-padding
// encoding, used only to construct fixtures above -- EgtVerifier has its
// own internal decode side, kept private to that file on purpose).

private func base64urlEncode(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}
