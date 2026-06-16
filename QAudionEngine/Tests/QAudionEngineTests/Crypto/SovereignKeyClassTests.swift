import XCTest
@testable import QAudionEngine

/// KMS-rotation-v2 Phase-1 (D1) — `SovereignKeyVault.KeyClass` parse semantics.
///
/// The Keychain round-trip itself (`storePsk(...,keyClass:)` → `getKeyClass`)
/// needs a real Keychain (app host + entitlement) and so is exercised only on
/// device / in the app-target Keychain tests, NOT in `swift test` (which has no
/// Keychain access). What IS host-runnable — and what the D4 require-hw-only
/// abort hinges on — is the LENIENT-DEFAULT parse: an absent / unknown class
/// string MUST resolve to `.shared`, never `.hwOnly`, so a legacy entry can
/// never spuriously trip the abort. That safe default is pinned here.
final class SovereignKeyClassTests: XCTestCase {

    func testKnownClassesParseExactly() {
        XCTAssertEqual(SovereignKeyVault.KeyClass.parse("shared"),  .shared)
        XCTAssertEqual(SovereignKeyVault.KeyClass.parse("hw_only"), .hwOnly)
        XCTAssertEqual(SovereignKeyVault.KeyClass.parse("sw_only"), .swOnly)
    }

    /// nil / empty / unknown → `.shared`. This is the additive-safe default:
    /// a contact whose class was never recorded is a plain shared PSK, so D4
    /// (abort iff a hw_only contact yields no/!=hw_only fp) cannot misfire on it.
    func testUnknownAndNilDefaultToShared() {
        XCTAssertEqual(SovereignKeyVault.KeyClass.parse(nil),        .shared)
        XCTAssertEqual(SovereignKeyVault.KeyClass.parse(""),         .shared)
        XCTAssertEqual(SovereignKeyVault.KeyClass.parse("HW_ONLY"),  .shared) // case-sensitive wire
        XCTAssertEqual(SovereignKeyVault.KeyClass.parse("bogus"),    .shared)
    }

    /// The wire strings MUST equal the cross-platform contract (Android
    /// `KmsKey.keyClass`, firmware contact_meta, KmsTransport.KeyClassV2).
    func testRawValuesMatchCrossPlatformWire() {
        XCTAssertEqual(SovereignKeyVault.KeyClass.shared.rawValue,  "shared")
        XCTAssertEqual(SovereignKeyVault.KeyClass.hwOnly.rawValue,  "hw_only")
        XCTAssertEqual(SovereignKeyVault.KeyClass.swOnly.rawValue,  "sw_only")
    }
}
