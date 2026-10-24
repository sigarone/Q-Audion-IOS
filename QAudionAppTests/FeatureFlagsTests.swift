import XCTest
@testable import QAudionApp

/// `FeatureFlags` is a process-wide singleton (`shared`, private init), so these
/// tests only use seams that already exist: the typed lookups with keys no
/// flags.json will ever carry, `startAuthenticated(apiBaseUrl:getToken:)` with an
/// injected token provider, and `clearOverlay()`. Nothing here touches the
/// network: a provider that answers nil/empty makes `refreshOverlay()` return
/// before it builds a request.
///
/// NOT yet wired into CI: `QAudionApp/project-apptests.yml` (`includes`) and the
/// `-only-testing` list of `.github/workflows/ios-app-tests.yml` are the two places
/// to add `FeatureFlagsTests.swift` / `FeatureFlagsTests` (both files are outside
/// the scope of the change that added this test).
@MainActor
final class FeatureFlagsTests: XCTestCase {

    private func unknownKey() -> String {
        "test.featureflags.unknown." + UUID().uuidString
    }

    func test_bool_absentKey_returnsCompiledDefault() {
        let key = unknownKey()
        XCTAssertTrue(FeatureFlags.bool(key, true))
        XCTAssertFalse(FeatureFlags.bool(key, false))
    }

    func test_string_absentKey_returnsCompiledDefault() {
        let key = unknownKey()
        XCTAssertEqual(FeatureFlags.string(key, "fallback"), "fallback")
        XCTAssertEqual(FeatureFlags.string(key, ""), "")
    }

    /// The overlay is armed with a token provider; a nil token must mean "no
    /// request" (the provider is consulted, nothing else happens) and must not
    /// change how an unknown key resolves.
    func test_startAuthenticated_nilToken_consultsProviderAndLeavesDefaultsAlone() {
        FeatureFlags.shared.clearOverlay()
        var providerCalls = 0
        FeatureFlags.shared.startAuthenticated(apiBaseUrl: "https://flags.invalid") {
            providerCalls += 1
            return nil
        }
        XCTAssertEqual(providerCalls, 1, "arming the overlay consults the token provider exactly once")
        XCTAssertTrue(FeatureFlags.bool(unknownKey(), true))
    }

    /// An empty token is treated like no token: still no request, still defaults.
    func test_refreshOverlay_emptyToken_isNoOp() {
        var providerCalls = 0
        FeatureFlags.shared.startAuthenticated(apiBaseUrl: "https://flags.invalid") {
            providerCalls += 1
            return ""
        }
        let before = providerCalls
        FeatureFlags.shared.refreshOverlay()
        XCTAssertEqual(providerCalls, before + 1, "each refresh consults the provider once")
        XCTAssertFalse(FeatureFlags.bool(unknownKey(), false))
    }

    /// Sign-out path: the persisted overlay is dropped so the next account on
    /// the device does not inherit it.
    func test_clearOverlay_removesPersistedOverlay() {
        UserDefaults.standard.set(Data("{}".utf8), forKey: "qaudion.featureflags.overlay.v1")
        FeatureFlags.shared.clearOverlay()
        XCTAssertNil(UserDefaults.standard.object(forKey: "qaudion.featureflags.overlay.v1"))
    }

    // MARK: - Overlay response shape

    func test_parseOverlayResponse_readsFlagsObject() {
        let body = Data(#"{"flags":{"location_share.enabled":true,"LOG_OTLP_EXPORT_ENABLED":false,"mode":"x","n":1,"nested":{"a":true}},"entitlement_pubkey":{"kid":"k","alg":"ed25519"}}"#.utf8)
        let map = FeatureFlags.parseOverlayResponse(body)
        XCTAssertEqual(map["location_share.enabled"] as? Bool, true)
        XCTAssertEqual(map["LOG_OTLP_EXPORT_ENABLED"] as? Bool, false)
        XCTAssertEqual(map["mode"] as? String, "x")
        XCTAssertNil(map["entitlement_pubkey"])
        XCTAssertNil(map["nested"])
        XCTAssertEqual(map.count, 3)
    }

    func test_parseOverlayResponse_numericOneIsNotBool() {
        let body = Data(#"{"flags":{"location_share.enabled":1}}"#.utf8)
        XCTAssertNil(FeatureFlags.parseOverlayResponse(body)["location_share.enabled"])
    }

    func test_parseOverlayResponse_missingFlags_isEmpty() {
        let body = Data(#"{"location_share.enabled":true,"entitlement_pubkey":{}}"#.utf8)
        XCTAssertTrue(FeatureFlags.parseOverlayResponse(body).isEmpty)
    }

    func test_parseOverlayResponse_flagsNotObject_isEmpty() {
        XCTAssertTrue(FeatureFlags.parseOverlayResponse(Data(#"{"flags":[true]}"#.utf8)).isEmpty)
        XCTAssertTrue(FeatureFlags.parseOverlayResponse(Data(#"{"flags":"x"}"#.utf8)).isEmpty)
        XCTAssertTrue(FeatureFlags.parseOverlayResponse(Data("not json".utf8)).isEmpty)
    }
}
